=head1 NAME

 Servers::httpd::apache_fcgid::installer - i-MSCP Apache2/FastCGI Server implementation

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

package Servers::httpd::apache_fcgid::installer;

use strict;
use warnings;
use File::Basename;
use iMSCP::Config;
use iMSCP::Crypt qw/ randomStr /;
use iMSCP::Database;
use iMSCP::Debug;
use iMSCP::Dir;
use iMSCP::EventManager;
use iMSCP::Execute;
use iMSCP::File;
use iMSCP::Getopt;
use iMSCP::ProgramFinder;
use iMSCP::Rights;
use iMSCP::SystemGroup;
use iMSCP::SystemUser;
use iMSCP::TemplateParser;
use Servers::httpd::apache_fcgid;
use Servers::sqld;
use version;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 Installer for the i-MSCP Apache2/FastCGI Server implementation.

=head1 PUBLIC METHODS

=over 4

=item registerSetupListeners(\%eventManager)

 Register setup event listeners

 Param iMSCP::EventManager \%eventManager
 Return int 0 on success, other on failure

=cut

sub registerSetupListeners
{
    my ($self, $eventManager) = @_;

    $eventManager->register(
        'beforeSetupDialog',
        sub {
            push @{$_[0]}, sub { $self->showDialog( @_ ) };
            0;
        }
    );
}

=item showDialog(\%dialog)

 Show dialog

 Param iMSCP::Dialog \%dialog
 Return int 0 on success, other on failure

=cut

sub showDialog
{
    my ($self, $dialog) = @_;

    my $confLevel = main::setupGetQuestion( 'PHP_CONFIG_LEVEL', $self->{'phpConfig'}->{'PHP_CONFIG_LEVEL'} );

    if ($main::reconfigure =~ /^(?:httpd|php|servers|all|forced)$/ || $confLevel !~ /^per_(?:site|domain|user)$/) {
        $confLevel =~ s/_/ /;
        (my $rs, $confLevel) = $dialog->radiolist(
            <<"EOF", [ 'per_site', 'per_domain', 'per_user' ], $confLevel =~ /^per (?:user|domain)$/ ? $confLevel : 'per site' );

\\Z4\\Zb\\ZuPHP configuration level\\Zn

Please choose the PHP configuration level you want use. Available levels are:

\\Z4Per user:\\Zn One php.ini file per user
\\Z4Per domain:\\Zn One php.ini file per domain (including subdomains)
\\Z4Per site:\\Zn One php.ini file per domain
EOF
        return $rs if $rs >= 30;
    }

    ($self->{'phpConfig'}->{'PHP_CONFIG_LEVEL'} = $confLevel) =~ s/ /_/;
    0;
}

=item install()

 Process install tasks

 Return int 0 on success, other on failure

=cut

sub install
{
    my $self = shift;

    my $rs = $self->_setApacheVersion();
    $rs ||= $self->_makeDirs();
    $rs ||= $self->_copyDomainDisablePages;
    $rs ||= $self->_buildFastCgiConfFiles();
    $rs ||= $self->_buildApacheConfFiles();
    $rs ||= $self->_installLogrotate();
    $rs ||= $self->_setupVlogger();
    $rs ||= $self->_saveConf();
    $rs ||= $self->_cleanup();
}

=item setEnginePermissions

 Set engine permissions

 Return int 0 on success, other on failure

=cut

sub setEnginePermissions
{
    my $self = shift;

    my $rs = setRights(
        $self->{'phpConfig'}->{'PHP_FCGI_STARTER_DIR'},
        {
            user => $main::imscpConfig{'ROOT_USER'},
            group => $main::imscpConfig{'ROOT_GROUP'},
            mode => '0555'
        }
    );
    $rs ||= setRights(
        '/usr/local/sbin/vlogger',
        {
            user  => $main::imscpConfig{'ROOT_USER'},
            group => $main::imscpConfig{'ROOT_GROUP'},
            mode  => '0750'
        }
    );
    # Fix permissions on root log dir (e.g: /var/log/apache2) in any cases
    # Fix permissions on root log dir (e.g: /var/log/apache2) content only with --fix-permissions option
    $rs ||= setRights(
        $self->{'config'}->{'HTTPD_LOG_DIR'},
        {
            user      => $main::imscpConfig{'ROOT_USER'},
            group     => $main::imscpConfig{'ROOT_GROUP'},
            dirmode   => '0755',
            filemode  => '0644',
            recursive => 1
        }
    );
    $rs ||= setRights(
        $self->{'config'}->{'HTTPD_LOG_DIR'},
        {
            group => $main::imscpConfig{'ADM_GROUP'},
            mode  => '0750'
        }
    );
    $rs ||= setRights(
        "$main::imscpConfig{'USER_WEB_DIR'}/domain_disabled_pages",
        {
            user      => $main::imscpConfig{'ROOT_USER'},
            group     => $self->{'config'}->{'HTTPD_GROUP'},
            dirmode   => '0550',
            filemode  => '0440',
            recursive => 1
        }
    );
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init()

 Initialize instance

 Return Servers::httpd::apache_fcgid::installer

=cut

sub _init
{
    my $self = shift;

    $self->{'eventManager'} = iMSCP::EventManager->getInstance();
    $self->{'httpd'} = Servers::httpd::apache_fcgid->getInstance();
    $self->{'apacheCfgDir'} = $self->{'httpd'}->{'apacheCfgDir'};
    $self->{'config'} = $self->{'httpd'}->{'config'};

    # Be sure to work with newest conffile
    # Cover case where the conffile has been loaded prior installation of new files (even if discouraged)
    untie(%{$self->{'config'}});
    tie %{$self->{'config'}}, 'iMSCP::Config', fileName => "$self->{'apacheCfgDir'}/apache.data";
    
    my $oldConf = "$self->{'apacheCfgDir'}/apache.old.data";

    if(defined $main::execmode && $main::execmode eq 'setup' && -f $oldConf) {
        tie my %oldConfig, 'iMSCP::Config', fileName => $oldConf, readonly => 1;
        while(my($key, $value) = each(%oldConfig)) {
            next unless exists $self->{'config'}->{$key};
            $self->{'config'}->{$key} = $value;
        }
    }

    $self->{'phpCfgDir'} = $self->{'httpd'}->{'phpCfgDir'};
    $self->{'phpConfig'} = $self->{'httpd'}->{'phpConfig'};

    # Be sure to work with newest conffile
    # Cover case where the conffile has been loaded prior installation of new files (even if discouraged)
    untie(%{$self->{'phpConfig'}});
    tie %{$self->{'phpConfig'}}, 'iMSCP::Config', fileName => "$self->{'phpCfgDir'}/php.data";

    $oldConf = "$self->{'phpCfgDir'}/php.old.data";

    if(defined $main::execmode && $main::execmode eq 'setup' && -f $oldConf) {
        tie my %oldConfig, 'iMSCP::Config', fileName => $oldConf, readonly => 1;
        while(my($key, $value) = each(%oldConfig)) {
            next unless exists $self->{'phpConfig'}->{$key};
            $self->{'phpConfig'}->{$key} = $value;
        }
    }

    $self->_guessPhpVariables() if defined $main::execmode && $main::execmode eq 'setup';
    $self;
}

=item _guessPhpVariables

 Guess PHP Variables

 Return int 0 on success, die on failure

=cut

sub _guessPhpVariables
{
    my $self = shift;

    my ($phpVersion) = $main::imscpConfig{'PHP_SERVER'} =~ /^php([\d.]+)/;
    unless (defined $phpVersion) {
        die( sprintf( "Could not guess value for the `%s' PHP configuration parameter.", 'PHP_VERSION' ) );
    }

    $self->{'phpConfig'}->{'PHP_VERSION'} = $phpVersion;

    if (version->parse( $phpVersion ) < version->parse( '7.0' )) {
        $self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'} = '/etc/php5';
        $self->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'} = '/etc/php5/fpm/pool.d';
        $self->{'phpConfig'}->{'PHP_CLI_BIN_PATH'} = iMSCP::ProgramFinder::find( 'php5' ) || '';
        $self->{'phpConfig'}->{'PHP_FCGI_BIN_PATH'} = iMSCP::ProgramFinder::find( 'php5-cgi' ) || '';
        $self->{'phpConfig'}->{'PHP_FPM_BIN_PATH'} = iMSCP::ProgramFinder::find( 'php5-fpm' ) || '';
    } else {
        $self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'} = "/etc/php/$phpVersion";
        $self->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'} = "/etc/php/$phpVersion/fpm/pool.d";
        $self->{'phpConfig'}->{'PHP_CLI_BIN_PATH'} = iMSCP::ProgramFinder::find( "php$phpVersion" ) || '';
        $self->{'phpConfig'}->{'PHP_FCGI_BIN_PATH'} = iMSCP::ProgramFinder::find( "php-cgi$phpVersion" ) || '';
        $self->{'phpConfig'}->{'PHP_FPM_BIN_PATH'} = iMSCP::ProgramFinder::find( "php-fpm$phpVersion" ) || '';
    }

    unless (-d $self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'}) {
        $self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'} = '';
        die(
            sprintf(
                "Could not guess value for the `%s' PHP configuration parameter: %s directory doesn't exists.",
                'PHP_CONF_DIR_PATH',
                $self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'}
            )
        );
        $self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'} = '';
    }

    for(qw/ PHP_CLI_BIN_PATH PHP_FCGI_BIN_PATH /) {
        next unless $self->{'phpConfig'}->{$_} eq '';
        die( sprintf( "Could not guess value for the `%s' PHP configuration parameter.", $_ ) );
    }

    0;
}

=item _setApacheVersion()

 Set Apache version

 Return int 0 on success, other on failure

=cut

sub _setApacheVersion
{
    my $self = shift;

    my $rs = execute( 'apache2ctl -v', \my $stdout, \my $stderr );
    debug( $stdout ) if $stdout;
    error( $stderr || 'Unknown error' ) if $rs;
    return $rs if $rs;

    if ($stdout !~ m%Apache/([\d.]+)%) {
        error( 'Could not find Apache version from `apache2ctl -v` command output.' );
        return 1;
    }

    $self->{'config'}->{'HTTPD_VERSION'} = $1;
    debug( sprintf( 'Apache version set to: %s', $1 ) );
    0;
}

=item _makeDirs()

 Create directories

 Return int 0 on success, other on failure

=cut

sub _makeDirs
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdMakeDirs' );
    return $rs if $rs;

    # Remove any older fcgi starter directory (prevent possible orphaned file when changing PHP configuration level)
    $rs = iMSCP::Dir->new( dirname => $self->{'phpConfig'}->{'PHP_FCGI_STARTER_DIR'} )->remove();
    return $rs if $rs;

    for (
        [
            $self->{'config'}->{'HTTPD_LOG_DIR'},
            $main::imscpConfig{'ROOT_USER'},
            $main::imscpConfig{'ADM_GROUP'},
            0750
        ],
        [
            $self->{'phpConfig'}->{'PHP_FCGI_STARTER_DIR'},
            $main::imscpConfig{'ROOT_USER'},
            $main::imscpConfig{'ROOT_GROUP'},
            0555
        ]
    ) {
        $rs = iMSCP::Dir->new( dirname => $_->[0] )->make( { user => $_->[1], group => $_->[2], mode => $_->[3] } );
        return $rs if $rs;
    }

    $self->{'eventManager'}->trigger( 'afterHttpdMakeDirs' );
}

=item _copyDomainDisablePages()

 Copy pages for disabled domains

 Return int 0 on success, other on failure

=cut

sub _copyDomainDisablePages
{
    iMSCP::Dir->new( dirname => "$main::imscpConfig{'CONF_DIR'}/skel/domain_disabled_pages" )->rcopy(
        "$main::imscpConfig{'USER_WEB_DIR'}/domain_disabled_pages"
    );
}

=item _buildFastCgiConfFiles()

 Build FastCGI configuration files

 Return int 0 on success, other on failure

=cut

sub _buildFastCgiConfFiles
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdBuildFastCgiConfFiles' );
    my $version = $self->{'config'}->{'HTTPD_VERSION'};
    my $apache24 = version->parse( $version ) >= version->parse( '2.4.0' );

    $self->{'httpd'}->setData(
        {
            SYSTEM_USER_PREFIX   => $main::imscpConfig{'SYSTEM_USER_PREFIX'},
            SYSTEM_USER_MIN_UID  => $main::imscpConfig{'SYSTEM_USER_MIN_UID'},
            PHP_FCGI_STARTER_DIR => $self->{'phpConfig'}->{'PHP_FCGI_STARTER_DIR'},
            AUTHZ_ALLOW_ALL      => $apache24 ? 'Require all granted' : 'Allow from all'
        }
    );

    $rs = $self->{'httpd'}->buildConfFile(
        "$self->{'phpCfgDir'}/fcgi/apache_fcgid_module.conf",
        { },
        {
            destination => "$self->{'config'}->{'HTTPD_MODS_AVAILABLE_DIR'}/fcgid_imscp.conf"
        }
    );
    return $rs if $rs;

    my $file = iMSCP::File->new( filename => "$self->{'config'}->{'HTTPD_MODS_AVAILABLE_DIR'}/fcgid.load" );

    my $cfgTpl = $file->get();
    unless (defined $cfgTpl) {
        error( sprintf( 'Could not read %s file', $file->{'filename'} ) );
        return 1;
    }

    $file = iMSCP::File->new( filename => "$self->{'config'}->{'HTTPD_MODS_AVAILABLE_DIR'}/fcgid_imscp.load" );
    $cfgTpl = "<IfModule !mod_fcgid.c>\n".$cfgTpl."</IfModule>\n";

    $rs = $file->set( $cfgTpl );
    $rs ||= $file->save();
    $rs ||= $file->owner( $main::imscpConfig{'ROOT_USER'}, $main::imscpConfig{'ROOT_GROUP'} );
    $rs ||= $file->mode( 0644 );
    return $rs if $rs;

    # # Transitional: fastcgi_imscp
    my @modulesOff = ('fastcgi', 'fcgid', 'php5_cgi', 'php_fpm_imscp', 'fastcgi_imscp');
    my @modulesOn = ('actions', 'fcgid_imscp', 'version');

    if ($apache24) {
        push @modulesOff, 'mpm_event', 'mpm_itk', 'mpm_prefork';
        push @modulesOn, 'mpm_worker', 'authz_groupfile';
    }

    $rs = $self->{'httpd'}->disableModules( @modulesOff );
    $rs ||= $self->{'httpd'}->enableModules( @modulesOn );
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdBuildFastCgiConfFiles' );
}

=item _buildApacheConfFiles()

 Build Apache configuration files

 Return int 0 on success, other on failure

=cut

sub _buildApacheConfFiles
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdBuildApacheConfFiles' );
    return $rs if $rs;

    if (-f "$self->{'config'}->{'HTTPD_CONF_DIR'}/ports.conf") {
        $rs = $self->{'eventManager'}->trigger( 'onLoadTemplate', 'apache_fcgid', 'ports.conf', \ my $cfgTpl, { } );
        return $rs if $rs;

        unless (defined $cfgTpl) {
            $cfgTpl = iMSCP::File->new( filename => "$self->{'config'}->{'HTTPD_CONF_DIR'}/ports.conf" )->get();
            unless (defined $cfgTpl) {
                error( sprintf( 'Could not read %s file', "$self->{'config'}->{'HTTPD_CONF_DIR'}/ports.conf" ) );
                return 1;
            }
        }

        $rs = $self->{'eventManager'}->trigger( 'beforeHttpdBuildConfFile', \$cfgTpl, 'ports.conf' );
        return $rs if $rs;

        $cfgTpl =~ s/^(NameVirtualHost\s+\*:80)/#$1/gmi;

        $rs = $self->{'eventManager'}->trigger( 'afterHttpdBuildConfFile', \$cfgTpl, 'ports.conf' );
        return $rs if $rs;

        my $file = iMSCP::File->new( filename => "$self->{'config'}->{'HTTPD_CONF_DIR'}/ports.conf" );
        $rs = $file->set( $cfgTpl );
        $rs ||= $file->mode( 0644 );
        $rs ||= $file->save();
        return $rs if $rs;
    }

    # Turn off default access log provided by Debian package
    if (-d "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf-available") {
        $rs = $self->{'httpd'}->disableConfs( 'other-vhosts-access-log.conf' );
        return $rs if $rs;
    } elsif (-f "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/other-vhosts-access-log") {
        $rs = iMSCP::File->new(
            filename => "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/other-vhosts-access-log"
        )->delFile();
        return $rs if $rs;
    }

    # Remove default access log file provided by Debian package
    if (-f "$self->{'config'}->{'HTTPD_LOG_DIR'}/other_vhosts_access.log") {
        $rs = iMSCP::File->new( filename => "$self->{'config'}->{'HTTPD_LOG_DIR'}/other_vhosts_access.log" )->delFile();
        return $rs if $rs;
    }

    my $apache24 = version->parse( "$self->{'config'}->{'HTTPD_VERSION'}" ) >= version->parse( '2.4.0' );

    $self->{'httpd'}->setData(
        {
            HTTPD_CUSTOM_SITES_DIR => $self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'},
            HTTPD_LOG_DIR          => $self->{'config'}->{'HTTPD_LOG_DIR'},
            HTTPD_ROOT_DIR         => $self->{'config'}->{'HTTPD_ROOT_DIR'},
            AUTHZ_DENY_ALL         => $apache24 ? 'Require all denied' : 'Deny from all',
            AUTHZ_ALLOW_ALL        => $apache24 ? 'Require all granted' : 'Allow from all',
            PIPE                   =>
                version->parse( "$self->{'config'}->{'HTTPD_VERSION'}" ) >= version->parse( '2.2.12' ) ? '||' : '|',
            VLOGGER_CONF           => "$self->{'apacheCfgDir'}/vlogger.conf"
        }
    );
    $rs ||= $self->{'httpd'}->buildConfFile( '00_nameserver.conf' );
    $rs ||= $self->{'httpd'}->buildConfFile(
        '00_imscp.conf',
        { },
        {
            destination => -d "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf-available"
                ? "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf-available/00_imscp.conf"
                : "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/00_imscp.conf"
        }
    );
    $rs ||= $self->{'httpd'}->enableModules( 'cgid', 'headers', 'proxy', 'proxy_http', 'rewrite', 'setenvif', 'ssl', 'suexec' );
    $rs ||= $self->{'httpd'}->enableSites( '00_nameserver.conf' );
    $rs ||= $self->{'httpd'}->enableConfs( '00_imscp.conf' );
    $rs ||= $self->{'httpd'}->disableSites( 'default', 'default-ssl', '000-default.conf', 'default-ssl.conf' );
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdBuildApacheConfFiles' );
}

=item _installLogrotate()

 Install Apache logrotate file

 Return int 0 on success, other on failure

=cut

sub _installLogrotate
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdInstallLogrotate', 'apache2' );

    $self->{'httpd'}->setData(
        {
            ROOT_USER     => $main::imscpConfig{'ROOT_USER'},
            ADM_GROUP     => $main::imscpConfig{'ADM_GROUP'},
            HTTPD_LOG_DIR => $self->{'config'}->{'HTTPD_LOG_DIR'},
            PHP_VERSION   => $self->{'CONFIG'}->{'PHP_VERSION'}
        }
    );

    $rs ||= $self->{'httpd'}->buildConfFile(
        'logrotate.conf',
        { },
        { destination => "$main::imscpConfig{'LOGROTATE_CONF_DIR'}/apache2" }
    );
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdInstallLogrotate', 'apache2' );
}

=item _setupVlogger()

 Setup vlogger

 Return int 0 on success, other on failure

=cut

sub _setupVlogger
{
    my $self = shift;

    my $sqld = Servers::sqld->factory();
    my $host = main::setupGetQuestion( 'DATABASE_HOST' );
    $host = $host eq 'localhost' ? '127.0.0.1' : $host;
    my $port = main::setupGetQuestion( 'DATABASE_PORT' );
    my $dbName = main::setupGetQuestion( 'DATABASE_NAME' );
    my $user = 'vlogger_user';
    my $userHost = main::setupGetQuestion( 'DATABASE_USER_HOST' );
    $userHost = '127.0.0.1' if $userHost eq 'localhost';
    my $oldUserHost = $main::imscpOldConfig{'DATABASE_USER_HOST'} || '';
    my $pass = randomStr(16, iMSCP::Crypt::ALNUM);

    my $db = iMSCP::Database->factory();
    my $rs = main::setupImportSqlSchema( $db, "$self->{'apacheCfgDir'}/vlogger.sql" );
    return $rs if $rs;

    for ($userHost, $oldUserHost, 'localhost') {
        next unless $_;
        $sqld->dropUser( $user, $_ );
    }

    $sqld->createUser( $user, $userHost, $pass );

    # No need to escape wildcard characters. See https://bugs.mysql.com/bug.php?id=18660
    my $qDbName = $db->quoteIdentifier( $dbName );
    $rs = $db->doQuery( 'g', "GRANT SELECT, INSERT, UPDATE ON $qDbName.httpd_vlogger TO ?\@?", $user, $userHost );
    unless (ref $rs eq 'HASH') {
        error( sprintf( 'Could not add SQL privileges: %s', $rs ) );
        return 1;
    }

    $self->{'httpd'}->setData(
        {
            DATABASE_NAME     => $dbName,
            DATABASE_HOST     => $host,
            DATABASE_PORT     => $port,
            DATABASE_USER     => $user,
            DATABASE_PASSWORD => $pass
        }
    );

    $self->{'httpd'}->buildConfFile(
        "$self->{'apacheCfgDir'}/vlogger.conf.tpl",
        { SKIP_TEMPLATE_CLEANER => 1 },
        { destination => "$self->{'apacheCfgDir'}/vlogger.conf" }
    );
}

=item _saveConf()

 Save configuration file

 Return int 0 on success, other on failure

=cut

sub _saveConf
{
    my $self = shift;

    (tied %{$self->{'config'}})->flush();
    (tied %{$self->{'phpConfig'}})->flush();
    
    my %filesToDir = (
        'apache' => $self->{'apacheCfgDir'},
        'php'    => $self->{'phpCfgDir'}
    );

    for (keys %filesToDir) {
        my $rs = iMSCP::File->new( filename => "$filesToDir{$_}/$_.data" )->copyFile( "$filesToDir{$_}/$_.old.data" );
        return $rs if $rs;
    }

    0;
}

=item _cleanup()

 Process cleanup tasks

 Return int 0 on success, other on failure

=cut

sub _cleanup
{
    my $self = shift;

    my $rs ||= $self->{'httpd'}->disableSites( 'imscp.conf', '00_modcband.conf', '00_master.conf',
        '00_master_ssl.conf' );

    for ('imscp.conf', '00_modcband.conf', '00_master.conf', '00_master_ssl.conf') {
        next unless -f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$_";
        $rs = iMSCP::File->new( filename => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$_" )->delFile();
        return $rs if $rs;
    }

    if (-d $self->{'phpConfig'}->{'PHP_FCGI_STARTER_DIR'}) {
        $rs = execute(
            "rm -f $self->{'phpConfig'}->{'PHP_FCGI_STARTER_DIR'}/*/php5-fastcgi-starter", \ my $stdout, \ my $stderr
        );
        debug($stdout) if $stdout;
        error($stderr || 'Unknown error') if $rs;
        return $rs if $rs;
    }

    for ('/var/log/apache2/backup', '/var/log/apache2/users', '/var/www/scoreboards') {
        $rs = iMSCP::Dir->new( dirname => $_ )->remove();
        return $rs if $rs;
    }

    # Remove customer's logs file if any (no longer needed since we are now use bind mount)
    $rs = execute( "rm -f $main::imscpConfig{'USER_WEB_DIR'}/*/logs/*.log", \ my $stdout, \ my $stderr );
    debug($stdout) if $stdout;
    error( $stderr || 'Unknown error' ) if $rs;
    $rs;
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
