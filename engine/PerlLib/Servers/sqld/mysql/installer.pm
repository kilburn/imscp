=head1 NAME

 Servers::sqld::mysql::installer - i-MSCP MySQL server installer implementation

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2017 by Laurent Declercq <l.declercq@nuxwin.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

package Servers::sqld::mysql::installer;

use strict;
use warnings;
use iMSCP::Config;
use iMSCP::Crypt qw/ decryptRijndaelCBC /;
use iMSCP::Database;
use iMSCP::Debug;
use iMSCP::Dir;
use iMSCP::EventManager;
use iMSCP::Execute;
use iMSCP::File;
use iMSCP::ProgramFinder;
use iMSCP::Rights;
use iMSCP::TemplateParser;
use File::Temp;
use Servers::sqld::mysql;
use version;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 i-MSCP MySQL server installer implementation.

=head1 PUBLIC METHODS

=over 4

=item preinstall()

 Process preinstall tasks

 Return int 0 on success, other on failure

=cut

sub preinstall
{
    my $self = shift;

    my $rs = $self->_setTypeAndVersion();
    $rs ||= $self->_buildConf();
    $rs ||= $self->_updateServerConfig();
    $rs ||= $self->_saveConf();
}

=item setEnginePermissions()

 Set engine permissions

 Return int 0 on success, other on failure

=cut

sub setEnginePermissions
{
    my $self = shift;

    my $rs = setRights(
        "$self->{'config'}->{'SQLD_CONF_DIR'}/my.cnf",
        { user => $main::imscpConfig{'ROOT_USER'}, group => $main::imscpConfig{'ROOT_GROUP'}, mode => '0644' }
    );
    $rs ||= setRights(
        "$self->{'config'}->{'SQLD_CONF_DIR'}/conf.d/imscp.cnf",
        { user => $main::imscpConfig{'ROOT_USER'}, group => $self->{'config'}->{'SQLD_GROUP'}, mode => '0640' }
    );
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init()

 Initialize instance

 Return Servers::sqld::mysql:installer

=cut

sub _init
{
    my $self = shift;

    $self->{'eventManager'} = iMSCP::EventManager->getInstance();
    $self->{'sqld'} = Servers::sqld::mysql->getInstance();
    $self->{'cfgDir'} = $self->{'sqld'}->{'cfgDir'};
    $self->{'config'} = $self->{'sqld'}->{'config'};

    # Be sure to work with newest conffile
    # Cover case where the conffile has been loaded prior installation of new files (even if discouraged)
    untie(%{$self->{'config'}});
    tie %{$self->{'config'}}, 'iMSCP::Config', fileName => "$self->{'cfgDir'}/mysql.data";

    my $oldConf = "$self->{'cfgDir'}/mysql.old.data";

    if (defined $main::execmode && $main::execmode eq 'setup' && -f $oldConf) {
        tie my %oldConfig, 'iMSCP::Config', fileName => $oldConf, readonly => 1;
        while(my ($key, $value) = each(%oldConfig)) {
            next unless exists $self->{'config'}->{$key};
            $self->{'config'}->{$key} = $value;
        }
    }

    $self;
}

=item _setTypeAndVersion()

 Set SQL server type and version

 Return 0 on success, other on failure

=cut

sub _setTypeAndVersion
{
    my $self = shift;

    my $db = iMSCP::Database->factory();
    $db->set( 'FETCH_MODE', 'arrayref' );

    my $rdata = $db->doQuery( undef, 'SELECT @@version, @@version_comment' );
    if (ref $rdata ne 'ARRAY') {
        error( $rdata );
        return 1;
    }

    if (!@{$rdata}) {
        error( 'Could not find SQL server type and version' );
        return 1;
    }

    my $type = 'mysql';
    if (index( lc( ${$rdata}[0]->[0] ), 'mariadb' ) != - 1) {
        $type = 'mariadb';
    } elsif (index( lc( ${$rdata}[0]->[1] ), 'percona' ) != - 1) {
        $type = 'percona';
    }

    my ($version) = ${$rdata}[0]->[0] =~ /^([0-9]+(?:\.[0-9]+){1,2})/;
    unless (defined $version) {
        error( 'Could not find SQL server version' );
        return 1;
    }

    debug( sprintf( 'SQL server type set to: %s', $type ) );
    debug( sprintf( 'SQL server version set to: %s', $version ) );
    $self->{'config'}->{'SQLD_TYPE'} = $type;
    $self->{'config'}->{'SQLD_VERSION'} = $version;
    0;
}

=item _buildConf()

 Build configuration file

 Return int 0 on success, other on failure

=cut

sub _buildConf
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeSqldBuildConf' );
    return $rs if $rs;

    my $rootUName = $main::imscpConfig{'ROOT_USER'};
    my $rootGName = $main::imscpConfig{'ROOT_GROUP'};
    my $mysqlGName = $self->{'config'}->{'SQLD_GROUP'};
    my $confDir = $self->{'config'}->{'SQLD_CONF_DIR'};

    # Make sure that the conf.d directory exists
    $rs = iMSCP::Dir->new( dirname => "$confDir/conf.d" )->make(
        {
            user  => $rootUName,
            group => $rootGName,
            mode  => 0755
        }
    );
    return $rs if $rs;

    # Create the /etc/mysql/my.cnf file if missing
    unless (-f "$confDir/my.cnf") {
        $rs = $self->{'eventManager'}->trigger( 'onLoadTemplate', 'mysql', 'my.cnf', \my $cfgTpl, { } );
        return $rs if $rs;

        unless (defined $cfgTpl) {
            $cfgTpl = "!includedir $confDir/conf.d/\n";
        } elsif ($cfgTpl !~ m%^!includedir\s+$confDir/conf.d/\n%m) {
            $cfgTpl .= "!includedir $confDir/conf.d/\n";
        }

        my $file = iMSCP::File->new( filename => "$confDir/my.cnf" );
        $rs = $file->set( $cfgTpl );
        $rs ||= $file->save();
        $rs ||= $file->owner( $rootUName, $rootGName );
        $rs ||= $file->mode( 0644 );
        return $rs if $rs;
    }

    $rs ||= $self->{'eventManager'}->trigger( 'onLoadTemplate', 'mysql', 'imscp.cnf', \my $cfgTpl, { } );
    return $rs if $rs;

    unless (defined $cfgTpl) {
        $cfgTpl = iMSCP::File->new( filename => "$self->{'cfgDir'}/imscp.cnf" )->get();
        unless (defined $cfgTpl) {
            error( sprintf( 'Could not read %s', "$self->{'cfgDir'}/imscp.cnf" ) );
            return 1;
        }
    }

    $cfgTpl .= <<'EOF';
[mysqld]
performance_schema = 0
sql_mode = "NO_AUTO_CREATE_USER"
max_connections = 500
[mysql_upgrade]
host     = {DATABASE_HOST}
port     = {DATABASE_PORT}
user     = "{DATABASE_USER}"
password = "{DATABASE_PASSWORD}"
socket   = {SQLD_SOCK_DIR}/mysqld.sock
EOF

    (my $user = main::setupGetQuestion( 'DATABASE_USER' ) ) =~ s/"/\\"/g;
    (my $pwd = decryptRijndaelCBC( $main::imscpDBKey, $main::imscpDBiv, main::setupGetQuestion( 'DATABASE_PASSWORD' ) ) ) =~ s/"/\\"/g;
    my $variables = {
        DATABASE_HOST     => main::setupGetQuestion( 'DATABASE_HOST' ),
        DATABASE_PORT     => main::setupGetQuestion( 'DATABASE_PORT' ),
        DATABASE_USER     => $user,
        DATABASE_PASSWORD => $pwd,
        SQLD_SOCK_DIR     => $self->{'config'}->{'SQLD_SOCK_DIR'}
    };

    if (version->parse( "$self->{'config'}->{'SQLD_VERSION'}" ) >= version->parse( '5.5.0' )) {
        $cfgTpl =~ s/(\[mysqld\]\n)/$1innodb_use_native_aio = {INNODB_USE_NATIVE_AIO}\n/i;
        $variables->{'INNODB_USE_NATIVE_AIO'} = $self->_isMysqldInsideCt() ? '0' : '1';
    }

    # For backward compatibility - We will review this in later version
    # TODO Handle mariadb case when ready. See https://mariadb.atlassian.net/browse/MDEV-7597
    if (version->parse( "$self->{'config'}->{'SQLD_VERSION'}" ) >= version->parse( '5.7.4' )
        && $main::imscpConfig{'SQL_SERVER'} !~ /^mariadb/
    ) {
        $cfgTpl =~ s/(\[mysqld\]\n)/$1default_password_lifetime = 0\n/i;
    }

    $cfgTpl =~ s/(\[mysqld\]\n)/$1event_scheduler = DISABLED\n/i;
    $cfgTpl = process( $variables, $cfgTpl );

    my $file = iMSCP::File->new( filename => "$confDir/conf.d/imscp.cnf" );
    $rs ||= $file->set( $cfgTpl );
    $rs ||= $file->save();
    $rs ||= $file->owner( $rootUName, $mysqlGName );
    $rs ||= $file->mode( 0640 );
    return $rs if $rs;

    $self->{'eventManager'}->trigger( 'afterSqldBuildConf' );
}

=item _updateServerConfig()

 Update server configuration

  - Upgrade MySQL system tables if necessary
  - Disable unwanted plugins

 Return 0 on success, other on failure

=cut

sub _updateServerConfig
{
    my $self = shift;

    if (iMSCP::ProgramFinder::find( 'dpkg' ) && iMSCP::ProgramFinder::find( 'mysql_upgrade' )) {
        my $rs = execute(
            "dpkg -l mysql-community* percona-server-* | cut -d' ' -f1 | grep -q 'ii'", \my $stdout, \my $stderr
        );
        debug($stdout) if $stdout;
        debug($stderr) if $stderr;

        # Upgrade server system tables
        # See #IP-1482 for further details.
        unless ($rs) {
            my $host = main::setupGetQuestion( 'DATABASE_HOST' );
            (my $user = main::setupGetQuestion( 'SQL_ROOT_USER' )) =~ s/"/\\"/g;
            (my $pwd = main::setupGetQuestion( 'SQL_ROOT_PASSWORD' ) ) =~ s/"/\\"/g;
            my $conffile = File::Temp->new( UNLINK => 1 );

            print $conffile <<"EOF";
[mysql_upgrade]
host     = $host
user     = "$user"
password = "$pwd"
EOF
            $conffile->flush();

            # Filter all "duplicate column", "duplicate key" and "unknown column"
            # errors as the command is designed to be idempotent.
            $rs = execute(
                "mysql_upgrade --defaults-file=$conffile 2>&1 | egrep -v '^(1|\@had|ERROR (1054|1060|1061))'",
                \$stdout
            );
            error(sprintf('Could not upgrade SQL server system tables: %s', $stdout)) if $rs;
            return $rs if $rs;
            debug( $stdout ) if $stdout;
        }
    }

    my $db = iMSCP::Database->factory();

    # Set SQL mode (BC reasons)
    my $qrs = $db->doQuery( 's', "SET GLOBAL sql_mode = 'NO_AUTO_CREATE_USER'" );
    unless (ref $qrs eq 'HASH') {
        error( $qrs );
        return 1;
    }

    # Disable unwanted plugins (bc reasons)
    if (($main::imscpConfig{'SQL_SERVER'} =~ /^mariadb/
        && version->parse( "$self->{'config'}->{'SQLD_VERSION'}" ) >= version->parse( '10.0' ))
        || (version->parse( "$self->{'config'}->{'SQLD_VERSION'}" ) >= version->parse( '5.6.6' ))
    ) {
        for my $plugin(qw/ cracklib_password_check simple_password_check validate_password /) {
            $qrs = $db->doQuery( 'name', "SELECT name FROM mysql.plugin WHERE name = '$plugin'" );
            unless (ref $qrs eq 'HASH') {
                error( $qrs );
                return 1;
            }

            if (%{$qrs}) {
                $qrs = $db->doQuery( 'u', "UNINSTALL PLUGIN $plugin" );
                unless (ref $qrs eq 'HASH') {
                    error( $qrs );
                    return 1;
                }
            }
        }
    }

    0;
}

=item _saveConf()

 Save configuration file

 Return int 0 on success, other on failure

=cut

sub _saveConf
{
    my $self = shift;

    (tied %{$self->{'config'}})->flush();
    iMSCP::File->new( filename => "$self->{'cfgDir'}/mysql.data" )->copyFile( "$self->{'cfgDir'}/mysql.old.data" );
}

=item _isMysqldInsideCt()

 Does the Mysql server is run inside an unprivileged VE (OpenVZ container)

 Return int 1 if the Mysql server is run inside an OpenVZ container, 0 otherwise

=cut

sub _isMysqldInsideCt
{
    return 0 unless -f '/proc/user_beancounters';

    my $rs = execute( 'cat /proc/1/status | grep --color=never envID', \my $stdout, \my $stderr );
    debug( $stdout ) if $stdout;
    debug( $stderr ) if $rs && $stderr;
    return $rs if $rs;

    if ($stdout =~ /envID:\s+(\d+)/) {
        return ($1 > 0) ? 1 : 0;
    }

    0;
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
