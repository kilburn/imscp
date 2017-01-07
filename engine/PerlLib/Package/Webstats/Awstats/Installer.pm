=head1 NAME

Package::Webstats::Awstats::Installer - i-MSCP AWStats package installer

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

package Package::Webstats::Awstats::Installer;

use strict;
use warnings;
use iMSCP::Database;
use iMSCP::Debug;
use iMSCP::Dir;
use iMSCP::File;
use iMSCP::Rights;
use iMSCP::TemplateParser;
use Servers::cron;
use Servers::httpd;
use version;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 AWStats package installer.

 See Package::Webstats::Awstats::Awstats for more information.

=head1 PUBLIC METHODS

=over 4

=item install()

 Process install tasks

 Return int 0 on success, other on failure

=cut

sub install
{
    my $self = shift;

    my $rs = $self->_disableDefaultConfig();
    $rs ||= $self->_createCacheDir();
    $rs ||= $self->_setupApache2();
    $rs ||= $self->_addAwstatsCronTask();
}

=item setEnginePermissions()

 Set engine permissions

 Return int 0 on success, other on failure

=cut

sub setEnginePermissions
{
    my $self = shift;

    my $rs = setRights(
        "$main::imscpConfig{'ENGINE_ROOT_DIR'}/PerlLib/Package/Webstats/Awstats/Scripts/awstats_updateall.pl",
        {
            user  => $main::imscpConfig{'ROOT_USER'},
            group => $main::imscpConfig{'ROOT_USER'},
            mode  => '0700'
        }
    );
    $rs ||= setRights(
        $main::imscpConfig{'AWSTATS_CACHE_DIR'},
        {
            user      => $main::imscpConfig{'ROOT_USER'},
            group     => $self->{'httpd'}->getRunningGroup(),
            dirmode   => '02750',
            filemode  => '0640',
            recursive => 1
        }
    );
    $rs ||= setRights(
        "$self->{'httpd'}->{'config'}->{'HTTPD_CONF_DIR'}/.imscp_awstats",
        {
            user  => $main::imscpConfig{'ROOT_USER'},
            group => $self->{'httpd'}->getRunningGroup(),
            mode  => '0640'
        }
    );
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init()

 Initialize instance

 Return Package::Webstats::Awstats::Installer

=cut

sub _init
{
    my $self = shift;

    $self->{'httpd'} = Servers::httpd->factory();
    $self;
}

=item _createCacheDir()

 Create cache directory

 Return int 0 on success, other on failure

=cut

sub _createCacheDir
{
    my $self = shift;

    iMSCP::Dir->new( dirname => $main::imscpConfig{'AWSTATS_CACHE_DIR'} )->make(
        {
            user  => $main::imscpConfig{'ROOT_USER'},
            group => $self->{'httpd'}->getRunningGroup(),
            mode  => 02750
        }
    );
}

=item _setupApache2()

 Setup Apache2 for AWStats

 Return int 0 on success, other on failure

=cut

sub _setupApache2
{
    my $self = shift;

    # Create Basic authentication file

    my $file = iMSCP::File->new( filename => "$self->{'httpd'}->{'config'}->{'HTTPD_CONF_DIR'}/.imscp_awstats" );
    my $rs ||= $file->set(''); # Make sure to start with an empty file on update/reconfiguration
    $rs = $file->save();
    $rs ||= $file->owner( $main::imscpConfig{'ROOT_USER'}, $self->{'httpd'}->getRunningGroup() );
    $rs ||= $file->mode( 0640 );
    return $rs if $rs;

    my $isApache24 = version->parse( "$self->{'httpd'}->{'config'}->{'HTTPD_VERSION'}" ) >= version->parse( '2.4.0' );

    # Enable required Apache2 modules

    $rs = $isApache24
        ? $self->{'httpd'}->enableModules( 'rewrite', 'authn_core', 'authn_basic', 'authn_socache', 'proxy', 'proxy_http' )
        : $self->{'httpd'}->enableModules( 'rewrite', 'authn_core', 'authn_basic', 'proxy', 'proxy_http' );
    return $rs if $rs;

    # Create Apache2 vhost

    $self->{'httpd'}->setData(
        {
            AUTHZ_ALLOW_ALL             => $isApache24 ? 'Require all granted' : 'Allow from all',
            AWSTATS_AUTH_USER_FILE_PATH => "$self->{'httpd'}->{'config'}->{'HTTPD_CONF_DIR'}/.imscp_awstats",
            AWSTATS_ENGINE_DIR          => $main::imscpConfig{'AWSTATS_ENGINE_DIR'},
            AWSTATS_WEB_DIR             => $main::imscpConfig{'AWSTATS_WEB_DIR'},
            NAME_VIRTUALHOST            => $isApache24 ? '' : 'NameVirtualHost 127.0.0.1:8889'
        }
    );

    $rs = $self->{'httpd'}->buildConfFile(
        "$main::imscpConfig{'ENGINE_ROOT_DIR'}/PerlLib/Package/Webstats/Awstats/Config/01_awstats.conf"
    );
    $rs ||= $self->{'httpd'}->enableSites( '01_awstats.conf' );
}

=item _disableDefaultConfig()

 Disable default configuration

 Return int 0 on success, other on failure

=cut

sub _disableDefaultConfig
{
    my $rs = 0;

    if (-f "$main::imscpConfig{'AWSTATS_CONFIG_DIR'}/awstats.conf") {
        $rs = iMSCP::File->new( filename => "$main::imscpConfig{'AWSTATS_CONFIG_DIR'}/awstats.conf" )->moveFile(
            "$main::imscpConfig{'AWSTATS_CONFIG_DIR'}/awstats.conf.disabled"
        );
        return $rs if $rs;
    }

    my $cronDir = Servers::cron->factory()->{'config'}->{'CRON_D_DIR'};
    if (-f "$cronDir/awstats") {
        $rs = iMSCP::File->new( filename => "$cronDir/awstats" )->moveFile( "$cronDir/awstats.disable" );
    }

    $rs;
}

=item _addAwstatsCronTask()

 Add AWStats cron task for dynamic mode

 Return int 0 on success, other on failure

=cut

sub _addAwstatsCronTask
{
    Servers::cron->factory()->addTask(
        {
            TASKID  => 'Package::Webstats::Awstats',
            MINUTE  => '15',
            HOUR    => '3-21/6',
            DAY     => '*',
            MONTH   => '*',
            DWEEK   => '*',
            USER    => $main::imscpConfig{'ROOT_USER'},
            COMMAND => 'nice -n 15 ionice -c2 -n5 perl '.
                "$main::imscpConfig{'ENGINE_ROOT_DIR'}/PerlLib/Package/Webstats/Awstats/Scripts/awstats_updateall.pl now ".
                "-awstatsprog=$main::imscpConfig{'AWSTATS_ENGINE_DIR'}/awstats.pl > /dev/null 2>&1"
        }
    );
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
