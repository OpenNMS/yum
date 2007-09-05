#!/usr/bin/perl

use strict;
use warnings;

use File::Copy;
use File::Path;
use IO::Handle;

our $signing_password = shift @ARGV;

my @trees = qw(stable unstable);
my @oses  = qw(fc4 fc5 fc6 fc7 rhel3 rhel4 rhel5 suse9 suse10);

my $descriptions = {
	common => 'RPMs Common to All OpenNMS Architectures',
	fc4    => 'Fedora Core 4',
	fc5    => 'Fedora Core 5',
	fc6    => 'Fedora Core 6',
	fc7    => 'Fedora Core 7',
	rhel3  => 'RedHat Enterprise Linux 3.x and CentOS 3.x',
	rhel4  => 'RedHat Enterprise Linux 4.x and CentOS 4.x',
	rhel5  => 'RedHat Enterprise Linux 5.x and CentOS 5.x',
	suse9  => 'SuSE Linux 9.x',
	suse10 => 'SuSE Linux 10.x',
};

my $index = IO::Handle->new();
open($index, '>.index.html') or die "unable to write to index.html: $!";
print $index <<END;
<html>
 <head>
  <title>OpenNMS Yum Repository</title>
 </head>
 <body>
  <h1>OpenNMS Yum Repository</h1>
END

my @createrepo = qw(createrepo --verbose --pretty);

for my $tree (@trees) {
	my $title = ucfirst($tree);
	print $index "  <h2>$title</h2>\n";
	print $index "  <ul>\n";

	print $index "   <li>$descriptions->{'common'}</a> (<a href='$tree/common'>browse</a>)</li>\n";
	mkpath([$tree . '/common', 'caches/' . $tree . '/common', 'repofiles']);
	create_repo($tree, 'common');

	write_repofile($tree, 'common', $descriptions->{'common'});

	for my $os (@oses) {
		mkpath([$tree . '/' . $os, 'caches/' . $tree . '/' . $os, 'repofiles']);
		write_repofile($tree, $os, $descriptions->{$os});

		my $rpmname = make_rpm($tree, $os);
		print $index "   <li><a href='$tree/$os/opennms/$rpmname'>$descriptions->{$os}</a> (<a href='$tree/$os'>browse</a>)</li>\n";

		create_repo($tree, $os);
	}
	print $index "  </ul>\n";
}

print $index <<END;
 </body>
</html>
END

close ($index);

move('.index.html', 'index.html');

sub run_command {
	my @command = @_;

	print "- running '@command'\n";
	return system(@command);
}

sub create_repo {
	my $tree = shift;
	my $os   = shift;

	run_command('rm', '-rf', "$tree/$os/.olddata");


	# generate the repo
	run_command(
		@createrepo,
		'--baseurl', "http://yum.opennms.org/$tree/$os",
		'--outputdir', "$tree/$os",
		'--cachedir', "../../caches/$tree/$os",
		"$tree/$os",
	) == 0 or die "unable to run createrepo: $!";

	# sign the XML file
	run_command(
		'gpg',
		'--yes',
		'-a',
		'--detach-sign',
		'--passphrase', $signing_password,
		"$tree/$os/repodata/repomd.xml"
	) == 0 or die "unable to sign the repomd.xml file: $!";

	# write the signing public key for convenience
	run_command( "gpg -a --export opennms\@opennms.org > $tree/$os/repodata/repomd.xml.key" ) == 0
		or die "unable to export the public key: $!";
}

sub write_repofile {
	my $tree        = shift;
	my $os          = shift;
	my $description = shift;

	my $repofile = IO::Handle->new();
	open($repofile, ">repofiles/opennms-$tree-$os.repo") or die "unable to write to repofiles/opennms-$tree-$os.repo: $!";
	print $repofile <<END;
[opennms-$tree-$os]
name=$description RPMs ($tree)
baseurl=http://yum.opennms.org/$tree/$os
mirrorlist=http://yum.opennms.org/mirrorlists/$tree-$os.txt
failovermethod=priority
gpgcheck=1
gpgkey=http://yum.opennms.org/OPENNMS-GPG-KEY
END
	close($repofile);

	if (not -f "mirrorlists/$tree-$os.txt") {
		my $mirrorlist = IO::Handle->new();
		open ($mirrorlist, ">mirrorlists/$tree-$os.txt") or die "unable to write to mirrorlists/$tree-$os.txt: $!";
		print $mirrorlist "http://yum.opennms.org/$tree/$os\n";
		close ($mirrorlist);
	}
}

sub make_rpm {
	my $tree = shift;
	my $os   = shift;

	for my $dir ('tmp', 'SPECS', 'SOURCES', 'RPMS', 'SRPMS', 'BUILD') {
		mkpath(['/tmp/rpm-repo/' . $dir]);
	}
	copy("repofiles/opennms-$tree-$os.repo",    "/tmp/rpm-repo/SOURCES/");
	copy("repofiles/opennms-$tree-common.repo", "/tmp/rpm-repo/SOURCES/");

	run_command(
		"rpmbuild", "-bb",
		"--buildroot=/tmp/rpm-repo/tmp/buildroot",
		"--define", "_topdir /tmp/rpm-repo",
		"--define", "_tree $tree",
		"--define", "_osname $os",
		"repo.spec"
	) == 0 or die "unable to build rpm: $!";

	if (opendir(DIR, "/tmp/rpm-repo/RPMS/noarch")) {
		my @files;
		for my $file (readdir(DIR)) {
			chomp($file);
			if ($file =~ /\.rpm$/) {
				push(@files, $file);
			}
		}
		closedir(DIR);
		for my $file (@files) {
			mkpath(["$tree/$os/opennms"]);
			move("/tmp/rpm-repo/RPMS/noarch/$file", "$tree/$os/opennms/");
		}
		return($files[0]);
	}
}
