#!/usr/bin/perl
use strict;
use warnings;
use Authen::SASL;
use Net::LDAP;
use Net::LDAP::Control::ProxyAuth;
use Cwd qw(abs_path getcwd);
use File::Basename;
use File::Path qw(make_path remove_tree);
use Getopt::Long qw(:config no_ignore_case);
use lib qw(/root/bin/lib/perl5);

chomp(my $id = getpwuid($<));
if ($id ne "root") {
  print STDERR "Error: must be run as the root user\n";
  exit 1;
}

# GLOBALS
my $G_FULLSCRIPTNAME=abs_path($0);
my $G_SCRIPTNAME=basename($G_FULLSCRIPTNAME);
my $G_STARTDIR=getcwd();
chomp(my $G_HOSTNAME=qx(/usr/bin/hostname));
my $G_LOGFILE="/tmp/${G_SCRIPTNAME}.log";
chomp(my $G_DATESTAMP=qx(/usr/bin/date +'%Y%m%d%H%M'));
my $G_SCRIPTVERS="2019.1";

my $help;
my $HOMEDIRROOT="/export/home";
my $HOMEDIR="/home";
my $PROSROOT="/usr/local/adacnew";
my $PATIENTS="${PROSROOT}/Patients";
my $gid=1000;
my $shell="/usr/bin/csh";
my $adDomain="";
my $adUser="";
my $email="";
my $fullname;
my $uname;
my $uid;
my $P3RTP;
my $NOEMAIL;
my $PINN_SITE_DATA_DIR="${PROSROOT}/PinnacleSiteData";
my $PINN_LP_STATIC_DIR="${PROSROOT}/LPStatic";
my $RESOURCEFILE="Pinnacle_Install_Resources_Sol10.tgz";
my $CLIGROUP;

# options
my $opts_good = GetOptions(
  'h|help' => \$help,
  'f=s' => \$fullname,
  'a=s' => \$adUser,
  'r=s' => \$adDomain,
  'n=s' => \$uname,
  'p=s' => \$PROSROOT,
  'P' => \$P3RTP,
  'u=i' => \$uid,
  'g=s' => \$CLIGROUP,
  'd=s' => \$PATIENTS,
  'e=s' => \$email,
  'N' => \$NOEMAIL,
);

if (!$opts_good) {
  &PrintHelpAndExit();
}

if (defined($help)) {
  &PrintHelpAndExit();
}

# These are mutually exclusive options, exit if more than one is set.
&PrintHelpAndExit() if (grep($_, ${uname}, ${P3RTP}) > 1);

# If the system account is selected, quit if the remote user bits are set
&PrintHelpAndExit() if (defined($P3RTP) && $adDomain ne "" && $adUser ne "");

my $AVAILACCTID=1003;
while (qx(/usr/bin/getent passwd | awk -F: '{ print \$3; }' | grep -w ${AVAILACCTID})) {
  $AVAILACCTID++;
}
if (!defined($uid)) {
  $uid=$AVAILACCTID;
}

if(defined($uname)) {
  if ($uname eq "p3rtp") {
    &PrintHelpAndExit("$uname is a reserved login name",
      "no files copied, NOT setting up user account");
  }
  # check uid
  if ($uid < 1003 || $uid > 1999) {
    &PrintHelpAndExit("uid must be between 1003 and 1999, inclusive",
      "no files copied, NOT setting up user account");
  }
  # If creating a remote user, exit if only one of the two remote options is set
  if (($adUser eq "" && $adDomain ne "") || ($adDomain eq "" && $adUser ne "")) {
    &PrintHelpAndExit("Remote users require both the login and domain to be set.");
  }
  if($email eq "" && !defined($NOEMAIL)) {
    &PrintHelpAndExit("Email address required.");
  }
}

if(defined($P3RTP)) {
  $NOEMAIL=1;
}

sub PrintHelpAndExit() {
  if (@_ > 0) {
    print "\n\n";
    for (my $i=0; $i < @_; $i++) {
      if ($i == 0) {
        print "${G_SCRIPTNAME}: $_[$i]\n";
      } else {
        print "    $_[$i]\n";
      }
    }
    print "\n";
  }
print << "ENDOFTEXT";
usage:
     Add a local regular user:
       ${G_SCRIPTNAME} -n uname -f "fullname" -e email [-g gid] [-p prosroot] [-u uid]

     Add a remote regular user:
       ${G_SCRIPTNAME} -n uname -f "fullname" -e email -a user\@corp.domain -r corp.realm [-g gid] [-p prosroot] [-u uid]

     Add p3rtp user:
       ${G_SCRIPTNAME} -P

     Add other system users:
       ${G_SCRIPTNAME} -A
       ${G_SCRIPTNAME} -B
       ${G_SCRIPTNAME} -M

Local user usage:
  -n        The login name for the user. (REQUIRED)
  -f        Full name of the user.  Place inside double-quotes. (REQUIRED)
  -e        Email address for the user. (REQUIRED)
  -g        Set user's default group (group must exist!) (default: 1000)
  -p        Root path for Pinnacle directories (default: /usr/local/adacnew)
  -u        Number user ID for the user. Must be between 1003 and 1999. (default: next available in range)

Remote user usage:
   For remote authentication against active directory, the same options as provided
   for a local user with an additional two mandatory options:

  -a        Remote user login account (user\@corp.domain)
  -r        Remote realm (corp.realm)

System account user  usage (These are exclusive options):
  -P        Install the generic p3rtp user.  This can only be done once and
              is normally done after installing Pinnacle.

example: ${G_SCRIPTNAME} -n pinnuser -f "Pinnacle J. User" -e pinnuser\@example.com

ENDOFTEXT
    exit 1;
}

sub PrintErrorAndExit() {
  if (@_ > 0) {
    print "\n\n";
    for (my $i=0; $i < @_; $i++) {
      if ($i == 0) {
        print "${G_SCRIPTNAME}: $_[$i]\n";
      } else {
        print "    $_[$i]\n";
      }
    }
    print "\n";
  }
  exit 1;
}

print "${G_SCRIPTNAME}" . ' - Ver. $Revision: ' . "${G_SCRIPTVERS}" . ' $ - Copyright 2019 Philips Medical'."\n";

chomp(my $autofs_state = qx(/usr/bin/svcs -o state -H svc:/system/filesystem/autofs:default));
chomp(my $ldap_state = qx(/usr/bin/svcs -o state -H svc:/network/ldap/slapd:default));

if ($ldap_state ne "online") {
  &PrintErrorAndExit("must be run on the primary LDAP server");
}

if ( ! -d "${HOMEDIRROOT}" ) {
  &PrintErrorAndExit("can only be run when ${HOMEDIRROOT} exists as a directory.");
}

# if installing p3rtp user, set up necessary values
if (defined($P3RTP)) {
  if ( -d "$HOMEDIRROOT/p3rtp/.solregis") {
    &PrintHelpAndExit("The p3rtp user account already exists",
    "no files copied, NOT setting up p3rtp account");
  }
  if ( -d "$HOMEDIRROOT/p3rtp") {
    qx(/sbin/userdel -r -S ldap p3rtp);
    remove_tree("$HOMEDIRROOT/p3rtp");

    if ( "$autofs_state" eq "online" ) {
      qx(/sbin/svcadm disable svc:/system/filesystem/autofs:default);
      qx(/sbin/umount -f $HOMEDIRROOT/p3rtp);
      qx(/sbin/svcadm enable svc:/system/filesystem/autofs:default);
    }
  }
  $fullname="Generic Pinnacle User";
  $uname="p3rtp";
  $uid=1000;
}

# check validity of arguments
# check to make sure required variables were entered.
if ( !defined($fullname) ) {
    &PrintHelpAndExit("The full user name (-f) was not entered",
    "no files copied, NOT setting up user account");
}

if ( !defined($uname)) {
    &PrintHelpAndExit("The user login name (-n) was not entered",
    "no files copied, NOT setting up user account");
}

my $homeroot = "${HOMEDIRROOT}/${uname}";
my $homedir = "${HOMEDIR}/${uname}";

my $UNAME=uc($uname);

# check if homeroot already exists
if ( -d ${homeroot} ) {
    &PrintHelpAndExit("home directory \"${homeroot}\" already exists",
    "no files copied, NOT setting up user account");
}

# check if user already exists
chomp(my $tmpvar=qx(/usr/bin/getent passwd \'${uname}\'));
if ($tmpvar ne "") {
  &PrintHelpAndExit("${uname} aleady exists",
    "no files copied, NOT setting up user account");
}

# check if uid already exists
chomp($tmpvar = qx(/usr/bin/getent passwd | awk -F: '{ print \$3; }' | grep -w ${uid}));
if ($tmpvar ne "") {
  &PrintHelpAndExit("uid ${uid} already exists",
    "Next available uid is ${AVAILACCTID}");
}

if (defined($CLIGROUP)) {
  chomp($gid=qx(/usr/bin/getent group $CLIGROUP| awk -F: {'print \$3'}));
     # gid will return blank if it can't find the group.
   if ( $gid eq "" ) {
     &PrintHelpAndExit("Couldn't find GID for ${CLIGROUP}!");
   }
}

{
  my $ldap=Net::LDAP->new('ldapi://%2fvar%2fsymas%2frun%2fldapi/') or die "Could not open connection to local LDAP server.\n";
  my $sasl = Authen::SASL->new(
       mechanism => 'EXTERNAL'
       , callback => { user => '' }
       ) or die "$@";
  my $mesg = $ldap->bind(sasl => $sasl);
  my $auth = Net::LDAP::Control::ProxyAuth->new( authzID => 'dn:cn=admin,dc=philips,dc=com');
  my $userdn = "uid=${uname},ou=users,dc=philips,dc=com";
  $mesg = $ldap->add(
      $userdn,
      control => [ $auth ],
      attr => [
        objectClass=>["inetOrgPerson","posixAccount","shadowAccount"],
        uid=>"${uname}",
        cn=>"${uname}",
        sn=>"${uname}",
        uidNumber=>"${uid}",
        gidNumber=>"${gid}",
        gecos=>"${fullname}",
        homeDirectory=>"${homedir}",
        loginShell=>"${shell}",
      ],
    );
  if(!defined($NOEMAIL)) {
    $mesg = $ldap->modify(
        $userdn,
        control => [ $auth ],
        add=>[
          mail=>"${email}",
        ],
    );
  }
}

chomp($tmpvar=qx(/usr/bin/getent passwd \'${uname}\'));
if ($tmpvar eq "") {
  &PrintHelpAndExit("Failed to add user ${uname}");
}

# make the home directory (as well as the ~user/bin directory)
if ( ! -d "${homeroot}/bin" ) {
  make_path("${homeroot}/bin");
}

chdir(${homeroot});

# Untar the Solaris 11 resource tarball
qx(/usr/bin/gtar xvzf /root/bin/${RESOURCEFILE});

# Add PROSROOT and PATIENTS path to particular files
foreach (".dtprofile", ".environment", ".cshrc", ".tcshrc", ".profile", ".xinitrc", ".zshrc", ".zshenv",
    ".dt/dtwmrc", ".dt/en_US.ISO8859-1/dtwmrc", ".dt/en_US.ISO8859-1/dtwmrc_5.10",
    ".dt/en_US.ISO8859-1/dtwmrc_5.8", ".dt/types/Pinnacle.dt") {
  if ( -f "$_.dist" ) {
    my $infile="$_.dist";
    my $outfile="$_";
    open(IN, "<$infile") or die "Can't open $infile.\n";
    open(OUT, ">$outfile") or die "Can't open $outfile.\n";
    while(my $line = <IN>) {
      $line =~ s|=PROSROOT=|${PROSROOT}|g;
      $line =~ s|=PATIENTS=|${PATIENTS}|g;
      $line =~ s|=fullname=|${fullname}|;
      $line =~ s|=NAME=|${UNAME}|;
      $line =~ s|=NAME=|${UNAME}|;
      $line =~ s|=NAME=|${UNAME}|;
      $line =~ s|=NAME=|${UNAME}|;
      print OUT $line;
    }
    close(IN);
    close(OUT);
  }
}

# now create the resource file checksum file
my $sum=qx(cat /root/bin/${RESOURCEFILE} | /usr/bin/sum);
chomp($sum);
open(OUT, ">${homeroot}/.Sol10Resource.chk") or die "Can't open ${homeroot}/.Sol10Resource.chk for writing\n";
print OUT "$sum\n";
close(OUT);

# Create DefaultPinnacleInit in new users directory.
if ( -f "${HOMEDIRROOT}/${uname}/PinnacleInit" ) {
  print "Moving existing ${HOMEDIRROOT}/${uname}/PinnacleInit out of the way ...\n";
  my $rc=rename("${HOMEDIRROOT}/${uname}/PinnacleInit", "${HOMEDIRROOT}/${uname}/PinnacleInit.backup.$$");
  if ($rc == 0) {
    print "ERROR: Could not rename ${HOMEDIRROOT}/${uname}/PinnacleInit!\n";
  }
}

open(PI, ">${HOMEDIRROOT}/${uname}/PinnacleInit") || warn "Unable to write PinnacleInit";
print PI "// MaxThreads default value uses THREADS environment variable.\n";
print PI "// Modify at your own risk.\n";
print PI "MaxThreads=GetEnv.THREADS;\n";
close(PI);

qx(/usr/bin/chown -R \'${uname}\' \'${homeroot}\');
qx(/usr/bin/chgrp -Rh ${gid} \'${homeroot}\');
qx(/usr/bin/chmod 755 \'${homeroot}\');

if ($adDomain eq "") {
  print "\n\nEnter password for new user...\n";
  qx(/usr/bin/passwd -r ldap \'${uname}\');
} else {
  my $ldap=Net::LDAP->new('ldapi://%2fvar%2fsymas%2frun%2fldapi/') or die "Could not open connection to local LDAP server.\n";
  my $sasl = Authen::SASL->new(
       mechanism => 'EXTERNAL'
       , callback => { user => '' }
       ) or die "$@";
  my $mesg = $ldap->bind(sasl => $sasl);
  my $auth = Net::LDAP::Control::ProxyAuth->new( authzID => 'dn:cn=admin,dc=philips,dc=com');
  my $userdn = "uid=${uname},ou=users,dc=philips,dc=com";
  foreach my $attr ('userPassword', 'shadowLastChange', 'shadowFlag',
             'shadowMin', 'shadowMax', 'shadowWarning') {
    $mesg = $ldap->modify(
      $userdn,
      delete=>[$attr],
      control => [ $auth ],
    );
  }
  $mesg = $ldap->modify(
    $userdn,
    control => [ $auth ],
    add=> {
      objectClass=>'remoteauthUser',
      remoteauthDomainAttr=>$adDomain,
      remoteauthDnAttr=>$adUser,
    }
  );
}

if ($autofs_state eq "online") {
  qx(/sbin/svcadm restart autofs);
}

# is ok, exit 0
print "User ${uname} created successfully.\n";
exit 0;
