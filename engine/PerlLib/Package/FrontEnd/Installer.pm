=head1 NAME

Package::FrontEnd::Installer - i-MSCP FrontEnd package installer

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

package Package::FrontEnd::Installer;

use strict;
use warnings;
use Encode qw / decode_utf8 /;
use File::Basename;
use iMSCP::Config;
use iMSCP::Crypt qw/ apr1MD5 randomStr /;
use iMSCP::Database;
use iMSCP::Debug;
use iMSCP::Dialog::InputValidation;
use iMSCP::Dir;
use iMSCP::Execute;
use iMSCP::File;
use iMSCP::Getopt;
use iMSCP::OpenSSL;
use iMSCP::Rights;
use iMSCP::Net;
use iMSCP::ProgramFinder;
use iMSCP::SystemUser;
use iMSCP::TemplateParser;
use Net::LibIDN qw/ idn_to_ascii idn_to_unicode /;
use Package::FrontEnd;
use Servers::named;
use version;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 i-MSCP FrontEnd package installer.

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
            push @{$_[0]},
                sub { $self->askMasterAdminCredentials( @_ )},
                sub { $self->askMasterAdminEmail( @_ )},
                sub { $self->askDomain( @_ ) },
                sub { $self->askSsl( @_ ) },
                sub { $self->askHttpPorts( @_ ) };
            0;
        }
    );
}

=item askMasterAdminCredentials(\%dialog)

 Ask for master administrator credentials

 Param iMSCP::Dialog \%dialog
 Return int 0 or 30

=cut

sub askMasterAdminCredentials
{
    my (undef, $dialog) = @_;

    my ($username, $password) = ('', '');

    my $db = iMSCP::Database->factory();
    local $@;
    eval { $db->useDatabase( main::setupGetQuestion( 'DATABASE_NAME' ) ); };
    $db = undef if $@;

    if (iMSCP::Getopt->preseed) {
        $username = main::setupGetQuestion( 'ADMIN_LOGIN_NAME' );
        $password = main::setupGetQuestion( 'ADMIN_PASSWORD' );
    } elsif ($db) {
        my $defaultAdmin = $db->doQuery(
            'created_by',
            'SELECT admin_name, admin_pass, created_by FROM admin WHERE created_by = ? AND admin_type = ? LIMIT 1',
            '0',
            'admin'
        );
        unless (ref $defaultAdmin eq 'HASH') {
            error( $defaultAdmin );
            return 1;
        }

        if (%{$defaultAdmin}) {
            $username = $defaultAdmin->{'0'}->{'admin_name'} // '';
            $password = $defaultAdmin->{'0'}->{'admin_pass'} // '';
        }
    }

    main::setupSetQuestion( 'ADMIN_OLD_LOGIN_NAME', $username );

    if ($main::reconfigure =~ /^(?:admin|admin_credentials|all|forced)$/
        || !isValidUsername($username)
        || $password eq ''
    ) {
        $password = '';
        my ($rs, $msg) = (0, '');

        do {
            ($rs, $username) = $dialog->inputbox( <<"EOF", $username || 'admin' );

Please enter a username for the master administrator:$msg
EOF
            $msg = '';
            if (!isValidUsername($username)) {
                $msg = $iMSCP::Dialog::InputValidation::lastValidationError;
            } elsif ($db) {
                my $rdata = $db->doQuery(
                    'admin_id', 'SELECT admin_id FROM admin WHERE admin_name = ? AND created_by <> 0 LIMIT 1', $username
                );
                unless (ref $rdata eq 'HASH') {
                    error( $rdata );
                    return 1;
                } elsif (%{$rdata}) {
                    $msg = '\n\n\\Z1This username is not available.\\Zn\n\nPlease try again:'
                }
            }
        } while $rs < 30 && $msg;
        return $rs if $rs >= 30;

        do {
            ($rs, $password) = $dialog->inputbox( <<"EOF", randomStr(16, iMSCP::Crypt::ALNUM) );

Please enter a password for the master administrator:$msg
EOF
            $msg = (isValidPassword($password)) ? '' : $iMSCP::Dialog::InputValidation::lastValidationError;
        } while $rs < 30 && $msg;
        return $rs if $rs >= 30;
    } else {
        $password = '' unless iMSCP::Getopt->preseed
    }

    main::setupSetQuestion( 'ADMIN_LOGIN_NAME', $username );
    main::setupSetQuestion( 'ADMIN_PASSWORD', $password );
    0;
}

=item askMasterAdminEmail(\%dialog)

 Ask for master administrator email address

 Param iMSCP::Dialog \%dialog
 Return int 0 or 30

=cut

sub askMasterAdminEmail
{
    my (undef, $dialog) = @_;

    my $email = main::setupGetQuestion( 'DEFAULT_ADMIN_ADDRESS' );

    if ($main::reconfigure =~ /^(?:admin|admin_email|all|forced)$/
        || !isValidEmail($email)
    ) {
        my ($rs, $msg) = (0, '');

        do {
            ($rs, $email) = $dialog->inputbox( <<"EOF", $email );

Please enter an email address for the master administrator:$msg
EOF
            $msg = (isValidEmail($email)) ? '' : $iMSCP::Dialog::InputValidation::lastValidationError;
        } while $rs < 30 && $msg;
        return $rs if $rs >= 30;
    }

    main::setupSetQuestion( 'DEFAULT_ADMIN_ADDRESS', $email );
    0;
}

=item askDomain(\%dialog)

 Show for frontEnd domain name

 Param iMSCP::Dialog \%dialog
 Return int 0 or 30

=cut

sub askDomain
{
    my (undef, $dialog) = @_;

    my $domainName = main::setupGetQuestion( 'BASE_SERVER_VHOST' );

    if ($main::reconfigure =~ /^(?:panel|panel_hostname|hostnames|all|forced)$/
        || !isValidDomain($domainName)
    ) {
        unless ($domainName) {
            my @domainLabels = split /\./, main::setupGetQuestion( 'SERVER_HOSTNAME' );
            $domainName = 'panel.'.join( '.', @domainLabels[1 .. $#domainLabels] );
        }

        $domainName = decode_utf8( idn_to_unicode( $domainName, 'utf-8' ) );
        my ($rs, $msg) = (0, '');

        do {
            ($rs, $domainName) = $dialog->inputbox( <<"EOF", $domainName, 'utf-8' );

Please enter a domain name for the control panel:$msg
EOF
            $msg = (isValidDomain($domainName)) ? '' :  $iMSCP::Dialog::InputValidation::lastValidationError;
        } while $rs < 30 && $msg;
        return $rs if $rs >= 30;
    }

    main::setupSetQuestion( 'BASE_SERVER_VHOST', idn_to_ascii( $domainName, 'utf-8' ) );
    0;
}

=item askSsl(\%dialog)

 Ask for frontEnd SSL certificate

 Param iMSCP::Dialog \%dialog
 Return int 0 or 30

=cut

sub askSsl
{
    my (undef, $dialog) = @_;

    my $domainName = main::setupGetQuestion( 'BASE_SERVER_VHOST' );
    my $domainNameUnicode = decode_utf8( idn_to_unicode( $domainName, 'utf-8' ) );
    my $sslEnabled = main::setupGetQuestion( 'PANEL_SSL_ENABLED' );
    my $selfSignedCertificate = main::setupGetQuestion( 'PANEL_SSL_SELFSIGNED_CERTIFICATE', 'no' );
    my $privateKeyPath = main::setupGetQuestion( 'PANEL_SSL_PRIVATE_KEY_PATH', '/root' );
    my $passphrase = main::setupGetQuestion( 'PANEL_SSL_PRIVATE_KEY_PASSPHRASE' );
    my $certificatePath = main::setupGetQuestion( 'PANEL_SSL_CERTIFICATE_PATH', '/root' );
    my $caBundlePath = main::setupGetQuestion( 'PANEL_SSL_CA_BUNDLE_PATH', '/root' );
    my $baseServerVhostPrefix = main::setupGetQuestion( 'BASE_SERVER_VHOST_PREFIX', 'http://' );
    my $openSSL = iMSCP::OpenSSL->new();

    if ($main::reconfigure =~ /^(?:panel|panel_ssl|ssl|all|forced)$/
        || $sslEnabled !~ /^(?:yes|no)$/
        || ($sslEnabled eq 'yes' && $main::reconfigure =~ /^(?:panel_hostname|hostnames)$/)
    ) {
        my $rs = $dialog->yesno( <<"EOF", $sslEnabled eq 'no' ? 1 : 0 );

Do you want to enable SSL for the control panel?
EOF
        if ($rs == 0) {
            $sslEnabled = 'yes';
            $rs = $dialog->yesno( <<"EOF", $selfSignedCertificate eq 'no' ? 1 : 0 );

Do you have a SSL certificate for the $domainNameUnicode domain?
EOF
            if ($rs == 0) {
                my $msg = '';

                do {
                    $dialog->msgbox( <<"EOF" );

$msg
Please select your private key in next dialog.
EOF
                    do {
                        ($rs, $privateKeyPath) = $dialog->fselect( $privateKeyPath );
                    } while $rs < 30 && !($privateKeyPath && -f $privateKeyPath);
                    return $rs if $rs >= 30;

                    ($rs, $passphrase) = $dialog->passwordbox( <<"EOF", $passphrase );

Please enter the passphrase for your private key if any:
EOF
                    return $rs if $rs >= 30;

                    $openSSL->{'private_key_container_path'} = $privateKeyPath;
                    $openSSL->{'private_key_passphrase'} = $passphrase;

                    $msg = '';
                    if ($openSSL->validatePrivateKey()) {
                        getMessageByType( 'error', { remove => 1 } );
                        $msg = "\n\\Z1Invalid private key or passphrase.\\Zn\n\nPlease try again.";
                    }
                } while $rs < 30 && $msg;
                return $rs if $rs >= 30;

                $rs = $dialog->yesno( <<"EOF" );

Do you have a SSL CA Bundle?
EOF
                if ($rs == 0) {
                    do {
                        ($rs, $caBundlePath) = $dialog->fselect( $caBundlePath );
                    } while $rs < 30 && !($caBundlePath && -f $caBundlePath);
                    return $rs if $rs >= 30;

                    $openSSL->{'ca_bundle_container_path'} = $caBundlePath;
                } else {
                    $openSSL->{'ca_bundle_container_path'} = '';
                }

                $dialog->msgbox( <<"EOF" );

Please select your SSL certificate in next dialog.
EOF
                $rs = 1;
                do {
                    $dialog->msgbox(<<"EOF") unless $rs;
                    
\\Z1Invalid SSL certificate.\\Zn

Please try again.
EOF
                    do {
                        ($rs, $certificatePath) = $dialog->fselect( $certificatePath );
                    } while $rs < 30 && !($certificatePath && -f $certificatePath);
                    return $rs if $rs >= 30;

                    getMessageByType( 'error', { remove => 1 } );
                    $openSSL->{'certificate_container_path'} = $certificatePath;
                } while $rs < 30 && $openSSL->validateCertificate();
                return $rs if $rs >= 30;
            } else {
                $selfSignedCertificate = 'yes';
            }

            if ($sslEnabled eq 'yes') {
                ($rs, $baseServerVhostPrefix) = $dialog->radiolist(
                    <<"EOF", [ 'https', 'http' ], $baseServerVhostPrefix eq 'https://' ? 'https' : 'http' );

Please choose the default HTTP access mode for the control panel:
EOF
                $baseServerVhostPrefix .= '://'
            }
        } else {
            $sslEnabled = 'no';
        }
    } elsif ($sslEnabled eq 'yes' && !iMSCP::Getopt->preseed) {
        $openSSL->{'private_key_container_path'} = "$main::imscpConfig{'CONF_DIR'}/$domainName.pem";
        $openSSL->{'ca_bundle_container_path'} = "$main::imscpConfig{'CONF_DIR'}/$domainName.pem";
        $openSSL->{'certificate_container_path'} = "$main::imscpConfig{'CONF_DIR'}/$domainName.pem";

        if ($openSSL->validateCertificateChain()) {
            getMessageByType( 'error', { remove => 1 } );
            $dialog->msgbox( <<"EOF" );

Your SSL certificate for the control panel is missing or invalid.
EOF
            main::setupSetQuestion( 'PANEL_SSL_ENABLED', '' );
            goto &{askSsl};
        }

        # In case the certificate is valid, we skip SSL setup process
        main::setupSetQuestion( 'PANEL_SSL_SETUP', 'no' );
    }

    main::setupSetQuestion( 'PANEL_SSL_ENABLED', $sslEnabled );
    main::setupSetQuestion( 'PANEL_SSL_SELFSIGNED_CERTIFICATE', $selfSignedCertificate );
    main::setupSetQuestion( 'PANEL_SSL_PRIVATE_KEY_PATH', $privateKeyPath );
    main::setupSetQuestion( 'PANEL_SSL_PRIVATE_KEY_PASSPHRASE', $passphrase );
    main::setupSetQuestion( 'PANEL_SSL_CERTIFICATE_PATH', $certificatePath );
    main::setupSetQuestion( 'PANEL_SSL_CA_BUNDLE_PATH', $caBundlePath );
    main::setupSetQuestion( 'BASE_SERVER_VHOST_PREFIX', $sslEnabled eq 'yes' ? $baseServerVhostPrefix : 'http://' );
    0;
}

=item askHttpPorts(\%dialog)

 Ask for frontEnd http ports

 Param iMSCP::Dialog \%dialog
 Return int 0 or 30

=cut

sub askHttpPorts
{
    my (undef, $dialog) = @_;

    my $httpPort = main::setupGetQuestion( 'BASE_SERVER_VHOST_HTTP_PORT' );
    my $httpsPort = main::setupGetQuestion( 'BASE_SERVER_VHOST_HTTPS_PORT' );
    my $ssl = main::setupGetQuestion( 'PANEL_SSL_ENABLED' );
    my ($rs, $msg) = (0, '');

    if ($main::reconfigure =~ /^(?:panel|panel_ports|all|forced)$/
        || !isNumber($httpPort)
        || !isNumberInRange($httpPort, 1025, 65535)
        || !isStringNotInList($httpPort, $httpsPort)
    ) {
        do {
            ($rs, $httpPort) = $dialog->inputbox( <<"EOF", $httpPort ? $httpPort : 8880 );

Please enter the http port for the control panel:$msg
EOF
            $msg = '';
            if (!isNumber($httpPort)
                || !isNumberInRange($httpPort, 1025, 65535)
                || !isStringNotInList($httpPort, $httpsPort)
            ) {
                $msg = $iMSCP::Dialog::InputValidation::lastValidationError;
            }
        } while $rs < 30 && $msg;
        return $rs if $rs >= 30;
    }

    main::setupSetQuestion( 'BASE_SERVER_VHOST_HTTP_PORT', $httpPort );

    if ($ssl eq 'yes') {
        if ($main::reconfigure =~ /^(?:panel|panel_ports|all|forced)$/
            || !isNumber($httpsPort)
            || !isNumberInRange($httpsPort, 1025, 65535)
            || !isStringNotInList($httpsPort, $httpPort)
        ) {
            do {
                ($rs, $httpsPort) = $dialog->inputbox( <<"EOF", $httpsPort ? $httpsPort : 8443 );

Please enter the https port for the control panel:$msg
EOF
                $msg = '';
                if (!isNumber($httpsPort)
                    || !isNumberInRange($httpsPort, 1025, 65535)
                    || !isStringNotInList($httpsPort, $httpPort)
                ) {
                    $msg = $iMSCP::Dialog::InputValidation::lastValidationError;
                }
            } while $rs < 30 && $msg;
            return $rs if $rs >= 30;
        }
    } else {
        $httpsPort ||= 8443;
    }

    main::setupSetQuestion( 'BASE_SERVER_VHOST_HTTPS_PORT', $httpsPort );
    0;
}

=item install()

 Process install tasks

 Return int 0 on success, other on failure

=cut

sub install
{
    my $self = shift;

    my $rs = $self->_setupMasterAdmin();
    $rs ||= $self->_setupSsl();
    $rs ||= $self->_setHttpdVersion();
    $rs ||= $self->_addMasterWebUser();
    $rs ||= $self->_makeDirs();
    $rs ||= $self->_copyPhpBinary();
    $rs ||= $self->_buildPhpConfig();
    $rs ||= $self->_buildHttpdConfig();
    $rs ||= $self->_deleteDnsZone();
    $rs ||= $self->_addDnsZone();
    $rs ||= $self->_saveConfig();
}

=item dpkgPostInvokeTasks()

 Process dpkg post-invoke tasks

 See See #IP-1641 for further details.

 Return int 0 on success, other on failure

=cut

sub dpkgPostInvokeTasks
{
    my $self = shift;

    my $phpBinaryPath = (version->parse( "$self->{'phpConfig'}->{'PHP_VERSION'}" ) < version->parse( '7' ))
        ? iMSCP::ProgramFinder::find( "php$self->{'phpConfig'}->{'PHP_VERSION'}-fpm" )
        : iMSCP::ProgramFinder::find( "php-fpm$self->{'phpConfig'}->{'PHP_VERSION'}" );

    return 0 unless -f '/usr/local/sbin/imscp_panel' || defined $phpBinaryPath;

    if (-f _ && !defined $phpBinaryPath) { # Cover case where administrator removed the package
        my $rs = $self->{'frontend'}->stop();
        $rs ||= iMSCP::File->new( filename => '/usr/local/sbin/imscp_panel' )->delFile();
        return $rs;
    }

    if (-f _) {
        my $v1 = $self->getFullPhpVersionFor( $phpBinaryPath );
        my $v2 = $self->getFullPhpVersionFor( '/usr/local/sbin/imscp_panel' );
        return 0 unless defined $v1 && defined $v2 && $v1 ne $v2; # Don't act when not necessary
        debug(sprintf("Updating imscp_panel service PHP binary from version `%s' to version `%s'", $v2, $v1));
    }

    my $rs = $self->_copyPhpBinary();
    return $rs if $rs || !-f '/usr/local/etc/imscp_panel/php-fpm.conf';

    $self->{'frontend'}->restart();
}

=item setGuiPermissions()

 Set gui permissions

 Return int 0 on success, other on failure

=cut

sub setGuiPermissions
{
    my $panelUName = $main::imscpConfig{'SYSTEM_USER_PREFIX'}.$main::imscpConfig{'SYSTEM_USER_MIN_UID'};
    my $panelGName = $main::imscpConfig{'SYSTEM_USER_PREFIX'}.$main::imscpConfig{'SYSTEM_USER_MIN_UID'};
    my $guiRootDir = $main::imscpConfig{'GUI_ROOT_DIR'};

    my $rs = setRights(
        $guiRootDir,
        { user => $panelUName, group => $panelGName, dirmode => '0550', filemode => '0440', recursive => 1 }
    );
    $rs ||= setRights(
        "$guiRootDir/themes",
        { user => $panelUName, group => $panelGName, dirmode => '0550', filemode => '0440', recursive => 1 }
    );
    $rs ||= setRights(
        "$guiRootDir/data",
        { user => $panelUName, group => $panelGName, dirmode => '0750', filemode => '0640', recursive => 1 }
    );
    $rs ||= setRights(
        "$guiRootDir/data/persistent",
        { user => $panelUName, group => $panelGName, dirmode => '0750', filemode => '0640', recursive => 1 }
    );
    $rs ||= setRights(
        "$guiRootDir/i18n",
        { user => $panelUName, group => $panelGName, dirmode => '0750', filemode => '0640', recursive => 1 }
    );
    $rs ||= setRights(
        "$guiRootDir/plugins",
        { user => $panelUName, 'group' => $panelGName, 'dirmode' => '0750', 'filemode' => '0640', recursive => 1 }
    );
}

=item setEnginePermissions()

 Set engine permissions

 Return int 0 on success, other on failure

=cut

sub setEnginePermissions
{
    my $self = shift;

    my $rootUName = $main::imscpConfig{'ROOT_USER'};
    my $rootGName = $main::imscpConfig{'ROOT_GROUP'};
    my $httpdUser = $self->{'config'}->{'HTTPD_USER'};
    my $httpdGroup = $self->{'config'}->{'HTTPD_GROUP'};

    my $rs = setRights(
        $self->{'config'}->{'HTTPD_CONF_DIR'},
        { user => $rootUName, group => $rootGName, dirmode => '0755', filemode => '0644', recursive => 1 }
    );
    $rs ||= setRights(
        $self->{'config'}->{'HTTPD_LOG_DIR'},
        { user => $rootUName, group => $rootGName, dirmode => '0755', filemode => '0640', recursive => 1 }
    );
    return $rs if $rs;

    # Temporary directories as provided by nginx package (from Debian Team)
    if (-d "$self->{'config'}->{'HTTPD_CACHE_DIR_DEBIAN'}") {
        $rs = setRights( $self->{'config'}->{'HTTPD_CACHE_DIR_DEBIAN'}, { user => $rootUName, group => $rootGName } );

        for my $tmp('body', 'fastcgi', 'proxy', 'scgi', 'uwsgi') {
            next unless -d "$self->{'config'}->{'HTTPD_CACHE_DIR_DEBIAN'}/$tmp";

            $rs = setRights(
                "$self->{'config'}->{'HTTPD_CACHE_DIR_DEBIAN'}/$tmp",
                { user => $httpdUser, group => $httpdGroup, dirnmode => '0700', filemode => '0640', recursive => 1 }
            );
            $rs ||= setRights(
                "$self->{'config'}->{'HTTPD_CACHE_DIR_DEBIAN'}/$tmp",
                { user => $httpdUser, group => $rootGName, mode => '0700' }
            );
            return $rs if $rs;
        }
    }

    # Temporary directories as provided by nginx package (from nginx Team)
    return 0 unless -d "$self->{'config'}->{'HTTPD_CACHE_DIR_NGINX'}";

    $rs = setRights( $self->{'config'}->{'HTTPD_CACHE_DIR_NGINX'}, { user => $rootUName, group => $rootGName } );

    for my $tmp('client_temp', 'fastcgi_temp', 'proxy_temp', 'scgi_temp', 'uwsgi_temp') {
        next unless -d "$self->{'config'}->{'HTTPD_CACHE_DIR_NGINX'}/$tmp";

        $rs = setRights(
            "$self->{'config'}->{'HTTPD_CACHE_DIR_NGINX'}/$tmp",
            { user => $httpdUser, group => $httpdGroup, dirnmode => '0700', filemode => '0640', recursive => 1 }
        );
        $rs ||= setRights(
            "$self->{'config'}->{'HTTPD_CACHE_DIR_NGINX'}/$tmp",
            { user => $httpdUser, group => $rootGName, mode => '0700' }
        );
        return $rs if $rs;
    }

    0;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init()

 Initialize instance

 Return Package::FrontEnd::Installer

=cut

sub _init
{
    my $self = shift;

    $self->{'frontend'} = Package::FrontEnd->getInstance();
    $self->{'eventManager'} = $self->{'frontend'}->{'eventManager'};
    $self->{'cfgDir'} = $self->{'frontend'}->{'cfgDir'};
    $self->{'config'} = $self->{'frontend'}->{'config'};
    $self->{'phpConfig'} = $self->{'frontend'}->{'phpConfig'};

    # Be sure to work with newest conffile
    # Cover case where the conffile has been loaded prior installation of new files (even if discouraged)
    untie(%{$self->{'config'}});
    tie %{$self->{'config'}}, 'iMSCP::Config', fileName => "$self->{'cfgDir'}/frontend.data";

    if (defined $main::execmode && $main::execmode eq 'setup' && -f "$self->{'cfgDir'}/frontend.old.data") {
        tie my %oldConfig, 'iMSCP::Config', fileName => "$self->{'cfgDir'}/frontend.old.data", readonly => 1;
        while(my ($key, $value) = each(%oldConfig)) {
            next unless exists $self->{'config'}->{$key};
            $self->{'config'}->{$key} = $value;
        }
    }

    $self;
}

=item _setupMasterAdmin()

 Setup master administrator

 Return int 0 on success, other on failure

=cut

sub _setupMasterAdmin
{
    my $login = main::setupGetQuestion( 'ADMIN_LOGIN_NAME' );
    my $loginOld = main::setupGetQuestion( 'ADMIN_OLD_LOGIN_NAME' );
    my $password = main::setupGetQuestion( 'ADMIN_PASSWORD' );
    my $email = main::setupGetQuestion( 'DEFAULT_ADMIN_ADDRESS' );

    return 0 if $password eq '';

    $password = apr1MD5( $password );

    my $db = iMSCP::Database->factory();
    $db->useDatabase( main::setupGetQuestion( 'DATABASE_NAME' ) );

    my $rs = $db->doQuery(
        'admin_name', 'SELECT admin_id, admin_name FROM admin WHERE admin_name = ? LIMIT 1', $loginOld
    );
    unless (ref $rs eq 'HASH') {
        error( $rs );
        return 1;
    }

    if (%{$rs}) {
        $rs = $db->doQuery(
            'u', 'UPDATE admin SET admin_name = ?, admin_pass = ?, email = ? WHERE admin_id = ?',
            $login, $password, $email, $rs->{$loginOld}->{'admin_id'}
        );
        unless (ref $rs eq 'HASH') {
            error( $rs );
            return 1;
        }
        return 0;
    }

    $rs = $db->doQuery(
        'i', 'INSERT INTO admin (admin_name, admin_pass, admin_type, email) VALUES (?, ?, ?, ?)',
        $login, $password, 'admin', $email
    );
    unless (ref $rs eq 'HASH') {
        error( $rs );
        return 1;
    }

    $rs = $db->doQuery(
        'i',
        '
            INSERT IGNORE INTO user_gui_props (
                user_id, lang, layout, layout_color, logo, show_main_menu_labels
            ) VALUES (
                LAST_INSERT_ID(), ?, ?, ?, ?, ?
            )
        ',
        'auto', 'default', 'black', '', '0'
    );
    unless (ref $rs eq 'HASH') {
        error( $rs );
        return 1;
    }

    0
}

=item _setupSsl()

 Setup SSL

 Return int 0 on success, other on failure

=cut

sub _setupSsl
{
    my $sslEnabled = main::setupGetQuestion( 'PANEL_SSL_ENABLED' );
    my $oldCertificate = $main::imscpOldConfig{'BASE_SERVER_VHOST'}
        ? "$main::imscpOldConfig{'BASE_SERVER_VHOST'}.pem" : '';
    my $domainName = main::setupGetQuestion( 'BASE_SERVER_VHOST' );

    # Remove old certificate if any (handle case where panel hostname has been changed)
    if ($oldCertificate ne '' && $oldCertificate ne "$domainName.pem"
        && -f "$main::imscpConfig{'CONF_DIR'}/$oldCertificate"
    ) {
        my $rs = iMSCP::File->new( filename => "$main::imscpConfig{'CONF_DIR'}/$oldCertificate" )->delFile();
        return $rs if $rs;
    }

    if ($sslEnabled eq 'no' || main::setupGetQuestion( 'PANEL_SSL_SETUP', 'yes' ) eq 'no') {
        if ($sslEnabled eq 'no' && -f "$main::imscpConfig{'CONF_DIR'}/$domainName.pem") {
            my $rs = iMSCP::File->new( filename => "$main::imscpConfig{'CONF_DIR'}/$domainName.pem" )->delFile();
            return $rs if $rs;
        }

        return 0;
    }

    if (main::setupGetQuestion( 'PANEL_SSL_SELFSIGNED_CERTIFICATE' ) eq 'yes') {
        return iMSCP::OpenSSL->new(
            'certificate_chains_storage_dir' => $main::imscpConfig{'CONF_DIR'},
            'certificate_chain_name'         => $domainName
        )->createSelfSignedCertificate(
            {
                common_name => $domainName,
                email       => main::setupGetQuestion( 'DEFAULT_ADMIN_ADDRESS' )
            }
        );
    }

    iMSCP::OpenSSL->new(
        'certificate_chains_storage_dir' => $main::imscpConfig{'CONF_DIR'},
        'certificate_chain_name'         => $domainName,
        'private_key_container_path'     => main::setupGetQuestion( 'PANEL_SSL_PRIVATE_KEY_PATH' ),
        'private_key_passphrase'         => main::setupGetQuestion( 'PANEL_SSL_PRIVATE_KEY_PASSPHRASE' ),
        'certificate_container_path'     => main::setupGetQuestion( 'PANEL_SSL_CERTIFICATE_PATH' ),
        'ca_bundle_container_path'       => main::setupGetQuestion( 'PANEL_SSL_CA_BUNDLE_PATH' )
    )->createCertificateChain();
}

=item _setHttpdVersion()

 Set httpd version

 Return int 0 on success, other on failure

=cut

sub _setHttpdVersion()
{
    my $self = shift;

    my $rs = execute( 'nginx -v', \ my $stdout, \ my $stderr );
    debug( $stdout ) if $stdout;
    error( $stderr || 'Unknown error' ) if $rs;
    return $rs if $rs;

    if ($stderr !~ m%nginx/([\d.]+)%) {
        error( 'Could not find nginx Nginx from `nginx -v` command output.' );
        return 1;
    }

    $self->{'config'}->{'HTTPD_VERSION'} = $1;
    debug( sprintf( 'Nginx version set to: %s', $1 ) );
    0;
}

=item _addMasterWebUser()

 Add master Web user

 Return int 0 on success, other on failure

=cut

sub _addMasterWebUser
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeFrontEndAddUser' );
    return $rs if $rs;

    my $userName = my $groupName = $main::imscpConfig{'SYSTEM_USER_PREFIX'}.$main::imscpConfig{'SYSTEM_USER_MIN_UID'};

    my $db = iMSCP::Database->factory();
    $db->useDatabase( main::setupGetQuestion( 'DATABASE_NAME' ) );

    my $rdata = $db->doQuery(
        'admin_sys_uid',
        '
            SELECT admin_sys_name, admin_sys_uid, admin_sys_gname FROM admin
            WHERE admin_type = ? AND created_by = ? LIMIT 1
        ',
        'admin', '0'
    );

    unless (ref $rdata eq 'HASH') {
        error( $rdata );
        return 1;
    }

    if (!%{$rdata}) {
        error( 'Could not find admin user in database' );
        return 1;
    }

    my $adminSysName = $rdata->{(%{$rdata})[0]}->{'admin_sys_name'};
    my $adminSysUid = $rdata->{(%{$rdata})[0]}->{'admin_sys_uid'};
    my $adminSysGname = $rdata->{(%{$rdata})[0]}->{'admin_sys_gname'};
    my ($oldUserName, undef, $userUid, $userGid) = getpwuid( $adminSysUid );

    if (!$oldUserName || $userUid == 0) {
        # Creating i-MSCP Master Web user
        $rs = iMSCP::SystemUser->new(
            'username'       => $userName,
            'comment'        => 'i-MSCP Master Web User',
            'home'           => $main::imscpConfig{'GUI_ROOT_DIR'},
            'skipCreateHome' => 1
        )->addSystemUser();
        return $rs if $rs;

        $userUid = getpwnam( $userName );
        $userGid = getgrnam( $groupName );
    } else {
        my @cmd = (
            'pkill -KILL -u', escapeShell( $oldUserName ), ';',
            'usermod',
            '-c', escapeShell( 'i-MSCP Master Web User' ),
            '-d', escapeShell( $main::imscpConfig{'GUI_ROOT_DIR'} ),
            '-l', escapeShell( $userName ),
            '-m',
            escapeShell( $adminSysName )
        );

        $rs = execute( "@cmd", \ my $stdout, \ my $stderr );
        debug( $stdout ) if $stdout;
        debug( $stderr || 'Unknown error' ) if $rs;
        return $rs if $rs;

        @cmd = ('groupmod', '-n', escapeShell( $groupName ), escapeShell( $adminSysGname ));
        debug( $stdout ) if $stdout;
        debug( $stderr || 'Unknown error' ) if $rs;
        $rs = execute( "@cmd", \$stdout, \$stderr );
        return $rs if $rs;
    }

    # Update admin.admin_sys_name, admin.admin_sys_uid, admin.admin_sys_gname and admin.admin_sys_gid columns
    $rdata = $db->doQuery(
        'dummy',
        '
            UPDATE admin SET admin_sys_name = ?, admin_sys_uid = ?, admin_sys_gname = ?, admin_sys_gid = ?
            WHERE admin_type = ?
        ',
        $userName, $userUid, $groupName, $userGid, 'admin'
    );
    unless (ref $rdata eq 'HASH') {
        error( $rdata );
        return 1;
    }

    $rs = iMSCP::SystemUser->new( username => $userName )->addToGroup( $main::imscpConfig{'IMSCP_GROUP'} );
    $rs ||= iMSCP::SystemUser->new( username => $self->{'config'}->{'HTTPD_USER'} )->addToGroup( $groupName );
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdAddUser' );
}

=item _makeDirs()

 Create directories

 Return int 0 on success, other on failure

=cut

sub _makeDirs
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeFrontEndMakeDirs' );
    return $rs if $rs;

    my $rootUName = $main::imscpConfig{'ROOT_USER'};
    my $rootGName = $main::imscpConfig{'ROOT_GROUP'};
    my $phpStarterDir = $self->{'phpConfig'}->{'PHP_FCGI_STARTER_DIR'};

    # Ensure that FCGI starter directory exists
    $rs = iMSCP::Dir->new( dirname => $phpStarterDir )->make(
        {
            user  => $main::imscpConfig{'ROOT_USER'},
            group => $main::imscpConfig{'ROOT_GROUP'},
            mode  => 0555
        }
    );

    # Remove previous FCGI tree if any (needed to avoid any garbage from plugins)
    $rs ||= iMSCP::Dir->new( dirname => "$phpStarterDir/master" )->remove();
    return $rs if $rs;

    my $nginxTmpDir = $self->{'config'}->{'HTTPD_CACHE_DIR_DEBIAN'};
    unless (-d $nginxTmpDir) {
        $nginxTmpDir = $self->{'config'}->{'HTTPD_CACHE_DIR_NGINX'};
    }

    # Force re-creation of cache directory tree (needed to prevent any permissions problem from an old installation)
    # See #IP-1530
    iMSCP::Dir->new( dirname => $nginxTmpDir )->remove();

    for (
        [ $nginxTmpDir, $rootUName, $rootUName, 0755 ],
        [ $self->{'config'}->{'HTTPD_CONF_DIR'}, $rootUName, $rootUName, 0755 ],
        [ $self->{'config'}->{'HTTPD_LOG_DIR'}, $rootUName, $rootUName, 0755 ],
        [ $self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}, $rootUName, $rootUName, 0755 ],
        [ $self->{'config'}->{'HTTPD_SITES_ENABLED_DIR'}, $rootUName, $rootUName, 0755 ],
        [ $phpStarterDir, $rootUName, $rootGName, 0555 ]
    ) {
        $rs = iMSCP::Dir->new( dirname => $_->[0] )->make( { user => $_->[1], group => $_->[2], mode => $_->[3] } );
        return $rs if $rs;
    }

    $self->{'eventManager'}->trigger( 'afterFrontEndMakeDirs' );
}

=item _copyPhpBinary()

 Copy system PHP-FPM binary for imscp_panel service

 Return int 0 on success, other on failure

=cut

sub _copyPhpBinary
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeFrontEndCopyPhpBinary' );
    return $rs if $rs;

    my $phpBinaryPath = (version->parse( "$self->{'phpConfig'}->{'PHP_VERSION'}" ) < version->parse( '7' ))
        ? iMSCP::ProgramFinder::find( "php$self->{'phpConfig'}->{'PHP_VERSION'}-fpm" )
        : iMSCP::ProgramFinder::find( "php-fpm$self->{'phpConfig'}->{'PHP_VERSION'}" );

    unless (defined $phpBinaryPath) {
        error( 'Could not find system PHP-FPM binary' );
        return 1;
    }

    if (-f '/usr/local/sbin/imscp_panel') {
        $rs ||= iMSCP::File->new( filename => '/usr/local/sbin/imscp_panel' )->delFile();
    }

    $rs ||= iMSCP::File->new( filename => $self->{'phpConfig'}->{'PHP_FPM_BIN_PATH'} )->copyFile(
        '/usr/local/sbin/imscp_panel'
    );
    $rs ||= $self->{'eventManager'}->trigger( 'afterFrontEndCopyPhpBinary' );
}

=item _buildPhpConfig()

 Build PHP configuration

 Return int 0 on success, other on failure

=cut

sub _buildPhpConfig
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeFrontEndBuildPhpConfig' );
    return $rs if $rs;

    my $user = $main::imscpConfig{'SYSTEM_USER_PREFIX'}.$main::imscpConfig{'SYSTEM_USER_MIN_UID'};
    my $group = $main::imscpConfig{'SYSTEM_USER_PREFIX'}.$main::imscpConfig{'SYSTEM_USER_MIN_UID'};

    $rs = $self->{'frontend'}->buildConfFile(
        "$self->{'cfgDir'}/php-fpm.conf",
        {
            CHKROOTKIT_LOG            => $main::imscpConfig{'CHKROOTKIT_LOG'},
            CONF_DIR                  => $main::imscpConfig{'CONF_DIR'},
            DOMAIN                    => main::setupGetQuestion( 'BASE_SERVER_VHOST' ),
            DISTRO_OPENSSL_CNF        => $main::imscpConfig{'DISTRO_OPENSSL_CNF'},
            DISTRO_CA_BUNDLE          => $main::imscpConfig{'DISTRO_CA_BUNDLE'},
            FRONTEND_FCGI_CHILDREN    => $self->{'config'}->{'FRONTEND_FCGI_CHILDREN'},
            FRONTEND_FCGI_MAX_REQUEST => $self->{'config'}->{'FRONTEND_FCGI_MAX_REQUEST'},
            FRONTEND_GROUP            => $group,
            FRONTEND_USER             => $user,
            HOME_DIR                  => $main::imscpConfig{'GUI_ROOT_DIR'},
            PEAR_DIR                  => $self->{'phpConfig'}->{'PHP_PEAR_DIR'},
            OTHER_ROOTKIT_LOG         => $main::imscpConfig{'OTHER_ROOTKIT_LOG'} ne ''
                ? ":$main::imscpConfig{'OTHER_ROOTKIT_LOG'}" : '',
            RKHUNTER_LOG              => $main::imscpConfig{'RKHUNTER_LOG'},
            TIMEZONE                  => main::setupGetQuestion( 'TIMEZONE' ),
            WEB_DIR                   => $main::imscpConfig{'GUI_ROOT_DIR'},
        },
        {
            destination => "/usr/local/etc/imscp_panel/php-fpm.conf",
            user        => $main::imscpConfig{'ROOT_USER'},
            group       => $main::imscpConfig{'ROOT_GROUP'},
            mode        => 0640
        }
    );
    $rs ||= $self->{'frontend'}->buildConfFile(
        "$self->{'cfgDir'}/php.ini",
        {

            PEAR_DIR => $self->{'phpConfig'}->{'PHP_PEAR_DIR'},
            TIMEZONE => main::setupGetQuestion( 'TIMEZONE' ),
            WEB_DIR  => $main::imscpConfig{'GUI_ROOT_DIR'}
        },
        {
            destination => "/usr/local/etc/imscp_panel/php.ini",
            user        => $main::imscpConfig{'ROOT_USER'},
            group       => $main::imscpConfig{'ROOT_GROUP'},
            mode        => 0640,
        }
    );
    $rs ||= $self->{'eventManager'}->trigger( 'afterFrontEndBuildPhpConfig' );
}

=item _buildHttpdConfig()

 Build httpd configuration

 Return int 0 on success, other on failure

=cut

sub _buildHttpdConfig
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeFrontEndBuildHttpdConfig' );
    return $rs if $rs;

    my $nbCPUcores = $self->{'config'}->{'HTTPD_WORKER_PROCESSES'};

    if ($nbCPUcores eq 'auto') {
        $rs = execute( 'grep processor /proc/cpuinfo | wc -l', \ my $stdout, \ my $stderr );
        debug( $stdout ) if $stdout;
        debug($stderr) if $stderr;
        debug( 'Could not detect number of CPU cores. nginx worker_processes value set to 2' ) if $rs;

        unless ($rs) {
            chomp( $stdout );
            $nbCPUcores = $stdout;
            $nbCPUcores = 4 if $nbCPUcores > 4; # Limit number of workers
        } else {
            $nbCPUcores = 2;
        }
    }

    $rs = $self->{'frontend'}->buildConfFile(
        "$self->{'cfgDir'}/nginx.conf",
        {
            HTTPD_USER               => $self->{'config'}->{'HTTPD_USER'},
            HTTPD_WORKER_PROCESSES   => $nbCPUcores,
            HTTPD_WORKER_CONNECTIONS => $self->{'config'}->{'HTTPD_WORKER_CONNECTIONS'},
            HTTPD_RLIMIT_NOFILE      => $self->{'config'}->{'HTTPD_RLIMIT_NOFILE'},
            HTTPD_LOG_DIR            => $self->{'config'}->{'HTTPD_LOG_DIR'},
            HTTPD_PID_FILE           => $self->{'config'}->{'HTTPD_PID_FILE'},
            HTTPD_CONF_DIR           => $self->{'config'}->{'HTTPD_CONF_DIR'},
            HTTPD_LOG_DIR            => $self->{'config'}->{'HTTPD_LOG_DIR'},
            HTTPD_SITES_ENABLED_DIR  => $self->{'config'}->{'HTTPD_SITES_ENABLED_DIR'}
        },
        {
            destination => "$self->{'config'}->{'HTTPD_CONF_DIR'}/nginx.conf",
            user        => $main::imscpConfig{'ROOT_USER'},
            group       => $main::imscpConfig{'ROOT_GROUP'},
            mode        => 0644
        }
    );
    $rs = $self->{'frontend'}->buildConfFile(
        "$self->{'cfgDir'}/imscp_fastcgi.conf",
        { },
        {
            destination => "$self->{'config'}->{'HTTPD_CONF_DIR'}/imscp_fastcgi.conf",
            user        => $main::imscpConfig{'ROOT_USER'},
            group       => $main::imscpConfig{'ROOT_GROUP'},
            mode        => 0644
        }
    );
    $rs = $self->{'frontend'}->buildConfFile(
        "$self->{'cfgDir'}/imscp_php.conf",
        { },
        {
            destination => "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/imscp_php.conf",
            user        => $main::imscpConfig{'ROOT_USER'},
            group       => $main::imscpConfig{'ROOT_GROUP'},
            mode        => 0644
        }
    );
    $rs ||= $self->{'eventManager'}->trigger( 'afterFrontEndBuildHttpdConfig' );
    $rs ||= $self->{'eventManager'}->trigger( 'beforeFrontEndBuildHttpdVhosts' );
    return $rs if $rs;

    my $httpsPort = main::setupGetQuestion( 'BASE_SERVER_VHOST_HTTPS_PORT' );
    my $tplVars = {
        BASE_SERVER_VHOST            => main::setupGetQuestion( 'BASE_SERVER_VHOST' ),
        BASE_SERVER_IP               =>
            iMSCP::Net->getInstance()->getAddrVersion( main::setupGetQuestion( 'BASE_SERVER_IP' ) ) eq 'ipv4'
            ? main::setupGetQuestion( 'BASE_SERVER_IP' ) : '['.main::setupGetQuestion( 'BASE_SERVER_IP' ).']',
        BASE_SERVER_VHOST_HTTP_PORT  => main::setupGetQuestion( 'BASE_SERVER_VHOST_HTTP_PORT' ),
        BASE_SERVER_VHOST_HTTPS_PORT => $httpsPort,
        WEB_DIR                      => $main::imscpConfig{'GUI_ROOT_DIR'},
        CONF_DIR                     => $main::imscpConfig{'CONF_DIR'}
    };

    $rs = $self->{'eventManager'}->register(
        'afterFrontEndBuildConf',
        sub {
            my ($cfgTpl, $tplName) = @_;

            if ($tplName eq '00_master.conf') {
                if (main::setupGetQuestion( 'BASE_SERVER_VHOST_PREFIX' ) eq 'https://') {
                    $$cfgTpl = replaceBloc(
                        "# SECTION custom BEGIN.\n",
                        "# SECTION custom END.\n",
                        "    # SECTION custom BEGIN.\n".
                            getBloc(
                                "# SECTION custom BEGIN.\n",
                                "# SECTION custom END.\n",
                                $$cfgTpl
                            ).
                            "    rewrite .* https://\$host:$httpsPort\$request_uri redirect;\n".
                            "    # SECTION custom END.\n",
                        $$cfgTpl
                    );
                }

                unless (main::setupGetQuestion( 'IPV6_SUPPORT' )) {
                    $$cfgTpl = replaceBloc(
                        '# SECTION IPv6 BEGIN.',
                        '# SECTION IPv6 END.',
                        '',
                        $$cfgTpl
                    );
                }
            } elsif ($tplName eq '00_master_ssl.conf' && !main::setupGetQuestion( 'IPV6_SUPPORT' )) {
                $$cfgTpl = replaceBloc(
                    '# SECTION IPv6 BEGIN.',
                    '# SECTION IPv6 END.',
                    '',
                    $$cfgTpl
                );
            }

            0;
        }
    );
    $rs ||= $self->{'frontend'}->disableSites( 'default', '00_master.conf', '00_master_ssl.conf' );
    $rs ||= $self->{'frontend'}->buildConfFile(
        '00_master.conf',
        $tplVars,
        {
            destination => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/00_master.conf",
            user        => $main::imscpConfig{'ROOT_USER'},
            group       => $main::imscpConfig{'ROOT_GROUP'},
            mode        => 0644
        }
    );
    $rs ||= $self->{'frontend'}->enableSites( '00_master.conf' );
    return $rs if $rs;

    if (main::setupGetQuestion( 'PANEL_SSL_ENABLED' ) eq 'yes') {
        $rs = $self->{'frontend'}->buildConfFile(
            '00_master_ssl.conf',
            $tplVars,
            {
                destination => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/00_master_ssl.conf",
                user        => $main::imscpConfig{'ROOT_USER'},
                group       => $main::imscpConfig{'ROOT_GROUP'},
                mode        => 0644
            }
        );
        $rs ||= $self->{'frontend'}->enableSites( '00_master_ssl.conf' );
        return $rs if $rs;
    } elsif (-f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/00_master_ssl.conf") {
        $rs = iMSCP::File->new(
            filename => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/00_master_ssl.conf"
        )->delFile();
        return $rs if $rs;
    }

    if (-f "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/default.conf") {
        # Nginx package as provided by Nginx Team
        $rs = iMSCP::File->new( filename => "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/default.conf" )->moveFile(
            "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/default.conf.disabled"
        );
        return $rs if $rs;
    }

    $self->{'eventManager'}->trigger( 'afterFrontEndBuildHttpdVhosts' );
}

=item _addDnsZone()

 Add DNS zone

 Return int 0 on success, other on failure

=cut

sub _addDnsZone
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeNamedAddMasterZone' );
    $rs ||= Servers::named->factory()->addDmn(
        {
            BASE_SERVER_VHOST     => main::setupGetQuestion( 'BASE_SERVER_VHOST' ),
            BASE_SERVER_IP        => main::setupGetQuestion( 'BASE_SERVER_IP' ),
            BASE_SERVER_PUBLIC_IP => main::setupGetQuestion( 'BASE_SERVER_PUBLIC_IP' ),
            DOMAIN_NAME           => main::setupGetQuestion( 'BASE_SERVER_VHOST' ),
            DOMAIN_IP             => main::setupGetQuestion( 'BASE_SERVER_IP' ),
            MAIL_ENABLED          => 1
        }
    );
    $rs ||= $self->{'eventManager'}->trigger( 'afterNamedAddMasterZone' );
}

=item _deleteDnsZone()

 Delete previous DNS zone if needed (i.e. case where BASER_SERVER_VHOST has been modified)

 Return int 0 on success, other on failure

=cut

sub _deleteDnsZone
{
    my $self = shift;

    return 0 unless $main::imscpOldConfig{'BASE_SERVER_VHOST'} &&
        $main::imscpOldConfig{'BASE_SERVER_VHOST'} ne main::setupGetQuestion( 'BASE_SERVER_VHOST' );

    my $rs = $self->{'eventManager'}->trigger( 'beforeNamedDeleteMasterZone' );
    $rs ||= Servers::named->factory()->deleteDmn( { DOMAIN_NAME => $main::imscpOldConfig{'BASE_SERVER_VHOST'} } );
    $rs ||= $self->{'eventManager'}->trigger( 'afterNamedDeleteMasterZone' );
}

=item _saveConfig()

 Save configuration

 Return int 0 on success, other on failure

=cut

sub _saveConfig
{
    my $self = shift;

    (tied %{$self->{'config'}})->flush();

    iMSCP::File->new( filename => "$self->{'cfgDir'}/frontend.data" )->copyFile(
        "$self->{'cfgDir'}/frontend.old.data"
    );
}

=item getFullPhpVersionFor($binaryPath)

 Get full PHP version for the given PHP binary

 Param string $binaryPath Path to PHP binary
 Return int 0 on success, other on failure

=cut

sub getFullPhpVersionFor
{
    my (undef, $binaryPath) = @_;

    my $rs = execute([ $binaryPath, '-nv' ], \my $stdout, \my $stderr );
    error($stderr || 'Unknown error') if $rs;
    return undef unless $stdout;
    $stdout =~ /PHP\s+([^\s]+)/;
    $1;
}

=back

=head1 AUTHOR

Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
