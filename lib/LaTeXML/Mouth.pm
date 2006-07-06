# /=====================================================================\ #
# |  LaTeXML::Mouth                                                     | #
# | Analog of TeX's Mouth: Tokenizes strings & files                    | #
# |=====================================================================| #
# | Part of LaTeXML:                                                    | #
# |  Public domain software, produced as part of work done by the       | #
# |  United States Government & not subject to copyright in the US.     | #
# |---------------------------------------------------------------------| #
# | Bruce Miller <bruce.miller@nist.gov>                        #_#     | #
# | http://dlmf.nist.gov/LaTeXML/                              (o o)    | #
# \=========================================================ooo==U==ooo=/ #

#**********************************************************************
# LaTeXML::Mouth
#    Read TeX Tokens from a String.
#**********************************************************************
package LaTeXML::Mouth;
use strict;
use LaTeXML::Global;
use LaTeXML::Object;
our @ISA = qw(LaTeXML::Object);

# If options include cattable=>$cattable, that table will be used
# instead of one from $STOMACH.
sub new {
  my($class,$string,%options)=@_;
  my $self = {string=>$string, source=>"Anonmymous String", includeComments=>0, %options};
  $$self{buffer}=[split("\n",$string)];
  bless $self,$class;
  $self->initialize;
  $self; }

sub initialize {
  my($self)=@_;
  $$self{lineno}=0;
  $$self{colno}=0;
  $$self{chars}=[];
  $$self{nchars}=0;
}

sub getNextLine {
  my($self)=@_;
  return undef unless scalar(@{$$self{buffer}});
  my $line = shift(@{$$self{buffer}});
  (scalar(@{$$self{buffer}}) ? $line . "\n" : $line); }	# No cr on last line!

sub hasMoreInput {
  my($self)=@_;
  ($$self{colno} < $$self{nchars}) || scalar(@{$$self{buffer}}); }

sub stringify {
  my($self)=@_;
  "Mouth[<string>\@$$self{lineno}x$$self{colno}]"; }

#**********************************************************************
sub getLocator {
  my($self,$long)=@_;
  my($l,$c)=($$self{lineno},$$self{colno});
  my $msg =  "at $$self{source}; line $l col $c";
  if($long && (defined $l || defined $c)){
    my $chars=$$self{chars};
    my $n = scalar(@$chars);
    my $p1 = join('',@$chars[0..$c-1]); chomp($p1);
    my $p2 = join('',@$chars[$c..$n-1]); chomp($p2);
    $msg .="\n  ".$p1."\n  ".(' ' x $c).'^'.' '.$p2; }
  $msg; }

#**********************************************************************
# See The TeXBook, Chapter 8, The Characters You Type, pp.46--47.
#**********************************************************************

# Some caches
my %LETTER =();
my %OTHER =();
my %ACTIVE =();

sub handle_escape {		# Read control sequence
  my($self)=@_;
  my $cattable = $LaTeXML::Mouth::CATTABLE;
  # NOTE: We're using control sequences WITH the \ prepended!!!
  my $cs = "\\";		# I need this standardized to be able to lookup tokens (A better way???)
  my $ch = $$self{chars}->[$$self{colno}++];
  my $cc = $$cattable{$ch};  $cc=CC_OTHER unless defined $cc;
  if ($cc == CC_SUPER) {
    ($ch,$cc)=super_kludge($self,$ch); }
  elsif($cc == CC_EOL){	# I _think_ this is what Knuth is sayin' !?!?
    ($ch,$cc)=(' ',CC_SPACE); }
  $cs .= $ch;
  if(($cc == CC_LETTER) || ($cc == CC_SPACE)){ # We'll skip whitespace here.
    if ($cc == CC_LETTER) {	# For letter, read more letters for csname.
      while (($$self{colno} < $$self{nchars}) 
	     && defined($cc=$$cattable{$ch=$$self{chars}->[$$self{colno}++]})
	     && (($cc == CC_LETTER) || ($cc==CC_SUPER))){
	if($cc == CC_SUPER){ 
	  ($ch,$cc)=super_kludge($self,$ch);
	  last if ($cc != CC_LETTER); }
	$cs .= $ch; }
      $$self{colno}--; }
    # Now, skip spaces
    while ( ($$self{colno} < $$self{nchars})
	    && defined($cc=$$cattable{$$self{chars}->[$$self{colno}++]})
	    && (($cc == CC_SPACE) || ($cc == CC_EOL) || ($cc == CC_SUPER))) {
      if ($cc == CC_SUPER) {
	($ch,$cc)=super_kludge($self,$ch); 
	last if ($cc != CC_SPACE) && ($cc != CC_EOL); }
    }
    $$self{colno}-- if ($$self{colno} < $$self{nchars});
  }
  T_CS($cs); }

sub handle_EOL {
  my($self)=@_;
  ($$self{colno}==1 ? T_CS('\par') 
   : ($STOMACH->lookupValue('preserveNewLines') ? Token("\n",CC_SPACE) : T_SPACE)); 
}

sub handle_comment {
  my($self)=@_;
  my $n = $$self{colno};
  $$self{colno} = $$self{nchars};
  my $comment = join('',@{$$self{chars}}[$n..$$self{nchars}-1]);
  $comment =~ s/^\s+//; $comment =~ s/\s+$//;
  ($$self{includeComments} && $comment ? T_COMMENT($comment) : $self->readToken); }

my @DISPATCH
  = ( \&handle_escape,		# T_ESCAPE
      T_BEGIN,			# T_BEGIN
      T_END,			# T_END
      T_MATH,			# T_MATH
      T_ALIGN,			# T_ALIGN
      \&handle_EOL,		# T_EOL
      T_PARAM,			# T_PARAM
      T_SUPER,			# T_SUPER
      T_SUB,			# T_SUB
      sub { $_[0]->readToken; }, # T_IGNORE
      T_SPACE,			 # T_SPACE
      sub { $LETTER{$_[1]} || ($LETTER{$_[1]}=Token($_[1],$_[2])); }, # T_LETTER
      sub { $OTHER{$_[1]} || ($OTHER{$_[1]}=Token($_[1],$_[2])); }, # T_OTHER
      sub { $ACTIVE{$_[1]} || ($ACTIVE{$_[1]}=Token($_[1],$_[2])); }, # T_ACTIVE
      \&handle_comment,		# T_COMMENT
      sub { Token($_[1],CC_OTHER); } # T_INVALID (we could get unicode!)
);

# Read the next token, or undef if exhausted.
# Yes, this is _really_ ugly. I'm trying to emulate TeX's mouth; 
# this has been slightly optimized, so it's even worse.
# Note that this also returns COMMENT tokens containing source comments,
# and also locator comments (file, line# info).
# LaTeXML::Gullet intercepts them and passes them on at appropriate times.
sub readToken {
  my($self)=@_;
  my $cattable = $$self{cattable} || $STOMACH->getCattable;
  local $LaTeXML::Mouth::CATTABLE = $cattable;
  # ===== Get next line, if we need to.
  if ($$self{colno} >= $$self{nchars}) {
    $$self{lineno}++;
    $$self{colno}=0;
    my $line = $self->getNextLine; 
    if (!defined $line) {	# Exhausted the input.
      $$self{chars}=[];
      $$self{nchars}=0;
      return undef;
    }
    $line =~ s/^\s+//; $line =~ s/\s*$/\n/s;
    $$self{chars}=[split('',$line)];
#    $$self{chars}=[split('',$line),chr(0),chr(0)]; # Padding, so we don't have to check nchars so much.
    $$self{nchars} = scalar(@{$$self{chars}});
    # Sneak a comment out, every so often.
    if(!($$self{lineno} % 25)){
      NoteProgress("[#$$self{lineno}]");
      return T_COMMENT("**** $$self{source} Line $$self{lineno} ****")
	if $$self{includeComments};
    }
  }
  # ==== Extract next token from line.
  my $ch = $$self{chars}->[$$self{colno}++];
  my $cc = $$cattable{$ch}; $cc=CC_OTHER unless defined $cc;
  if ($cc == CC_SUPER) {	# Possible convert ^^x
    ($ch,$cc)=super_kludge($self,$ch); }
  my $dispatch = $DISPATCH[$cc];
  (ref $dispatch eq 'CODE' ? &$dispatch($self,$ch,$cc) : $dispatch);
}

# If $ch is a superscript, peek at next chars; if another superscript, convert the
# char. In either case, return a $ch & catcode
sub super_kludge {
  my($self,$ch)=@_;
  if(($$self{colno}+1 < $$self{nchars})
     && ($ch eq $$self{chars}->[$$self{colno}])){
    my $c=ord($$self{chars}->[$$self{colno}+1]);
    my $ch = chr($c + ($c > 64 ? -64 : 64));
    splice(@{$$self{chars}},$$self{colno}-1,3,$ch);
    $$self{nchars} -= 2;
    my $cc =  $$LaTeXML::Mouth::CATTABLE{$ch};
    ($ch, (defined $cc ? $cc : CC_OTHER)); }
  else {
    ($ch, CC_SUPER); }}

#**********************************************************************
sub readLine {
  my($self)=@_;
  if($$self{colno} < $$self{nchars}){
    my $line = join('',@{$$self{chars}}[$$self{colno}..$$self{nchars}-1]);
    $$self{colno}=$$self{nchars}; 
    $line; }
  else {
    $self->getNextLine; }}

#**********************************************************************
# Read all tokens, until exhausted.
# Returns an empty Tokens list, if there is no input
# [But shouldn't it return undef?]
sub readTokens {
  my($self)=@_;
  my @tokens=();
  while(defined(my $token = $self->readToken())){
    push(@tokens,$token); }
  while(@tokens && $tokens[$#tokens]->getCatcode == CC_SPACE){ # Remove trailing space
    pop(@tokens); }
  Tokens(@tokens); }

#**********************************************************************
# LaTeXML::FileMouth
#    Read TeX Tokens from a file.
#**********************************************************************
package LaTeXML::FileMouth;
use strict;
use LaTeXML::Global;
our @ISA = qw(LaTeXML::Mouth);

sub new {
  my($class,$pathname, %options)=@_;
  local *IN;
  open(IN,$pathname) || Fatal("Can't read from $pathname");
  my $self = {pathname=>$pathname, source=>$pathname,
	      IN => *IN, includeComments=>1, %options};
  bless $self,$class;
  $self->initialize;
  $self;  }

sub hasMoreInput {
  my($self)=@_;
  ($$self{colno} < $$self{nchars}) || $$self{IN}; }

sub getNextLine {
  my($self)=@_;
  return undef unless $$self{IN};
  my $fh = \*{$$self{IN}};
  my $line = <$fh>;
  if(! defined $line){
    close($fh); $$self{IN}=undef;
    $line = $$self{after}; $$self{after}=undef; }
#  close(IN) unless defined $l;
#  $l || "\\endinput"; }
  $line; }

sub stringify {
  my($self)=@_;
  "FileMouth[$$self{pathname}\@$$self{lineno}x$$self{colno}]"; }

#**********************************************************************
1;


__END__

=pod 

=head1 LaTeXML::Mouth and LaTeXML::FileMouth

=head2 DESCRIPTION

C<LaTeXML::Mouth> tokenizes a string according to the current cattable in the L<LaTeXML::Stomach>.
C<LaTeXML::FileMouth> specializes C<LaTeXML::Mouth> to tokenize from a file.

=head2 Methods of LaTeXML::Mouth

=over 4

=item C<< $mouth = LaTeXML::Mouth->new($string,%options); >>

Creates a new Mouth reading from C<$string>.
An option is cattable to override the one from the current C<$STOMACH>.

=item C<< $mouth = LaTeXML::FileMouth->new($pathname,%options); >>

Creates a new FileMouth to read from the given file.

=item C<< $token = $tokens->readToken; >>

Returns the next L<LaTeXML::Token> from the source.

=item C<< $string = $tokens->getLocator($long); >>

Return a description of current position in the source, for reporting errors.

=back

