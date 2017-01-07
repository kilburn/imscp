=head1 NAME

 Modules::Subdomain - i-MSCP Subdomain module

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2017 by internet Multi Server Control Panel
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.

package Modules::Subdomain;

use strict;
use warnings;
use Encode qw/ decode_utf8 /;
use File::Spec;
use iMSCP::Database;
use iMSCP::Debug;
use iMSCP::Dir;
use iMSCP::Execute;
use iMSCP::OpenSSL;
use Net::LibIDN qw/idn_to_unicode/;
use Servers::httpd;
use parent 'Modules::Abstract';

=head1 DESCRIPTION

 i-MSCP Subdomain module.

=head1 PUBLIC METHODS

=over 4

=item getType()

 Get module type

 Return string Module type

=cut

sub getType
{
    'Sub';
}

=item process($subdomainId)

 Process module

 Param int $subdomainId Subdomain unique identifier
 Return int 0 on success, other on failure

=cut

sub process
{
    my ($self, $subdomainId) = @_;

    my $rs = $self->_loadData( $subdomainId );
    return $rs if $rs;

    my @sql;
    if ($self->{'subdomain_status'} =~ /^to(?:add|change|enable)$/) {
        $rs = $self->add();
        @sql = (
            'UPDATE subdomain SET subdomain_status = ? WHERE subdomain_id = ?',
            ($rs ? scalar getMessageByType( 'error' ) || 'Unknown error' : 'ok'), $subdomainId
        );
    } elsif ($self->{'subdomain_status'} eq 'todelete') {
        $rs = $self->delete();
        if ($rs) {
            @sql = (
                'UPDATE subdomain SET subdomain_status = ? WHERE subdomain_id = ?',
                scalar getMessageByType( 'error' ) || 'Unknown error', $subdomainId
            );
        } else {
            @sql = ('DELETE FROM subdomain WHERE subdomain_id = ?', $subdomainId);
        }
    } elsif ($self->{'subdomain_status'} eq 'todisable') {
        $rs = $self->disable();
        @sql = (
            'UPDATE subdomain SET subdomain_status = ? WHERE subdomain_id = ?',
            ($rs ? scalar getMessageByType( 'error' ) || 'Unknown error' : 'disabled'), $subdomainId
        );
    } elsif ($self->{'subdomain_status'} eq 'torestore') {
        $rs = $self->restore();
        @sql = (
            'UPDATE subdomain SET subdomain_status = ? WHERE subdomain_id = ?',
            ($rs ? scalar getMessageByType( 'error' ) || 'Unknown error' : 'ok'), $subdomainId
        );
    }

    my $rdata = iMSCP::Database->factory()->doQuery( 'dummy', @sql );
    unless (ref $rdata eq 'HASH') {
        error( $rdata );
        return 1;
    }

    $rs;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _loadData($subdomainId)

 Load data

 Param int $subdomainId Subdomain unique identifier
 Return int 0 on success, other on failure

=cut

sub _loadData
{
    my ($self, $subdomainId) = @_;

    my $rdata = iMSCP::Database->factory()->doQuery(
        'subdomain_id',
        "
            SELECT t1.*, t2.domain_name AS user_home, t2.domain_admin_id, t2.domain_php, t2.domain_cgi,
                t2.domain_traffic_limit, t2.domain_mailacc_limit, t2.domain_dns, t2.external_mail,
                t2.web_folder_protection, t3.ip_number, t4.mail_on_domain
            FROM subdomain AS t1
            INNER JOIN domain AS t2 ON (t1.domain_id = t2.domain_id)
            INNER JOIN server_ips AS t3 ON (t2.domain_ip_id = t3.ip_id)
            LEFT JOIN (
                SELECT sub_id, COUNT(sub_id) AS mail_on_domain FROM mail_users WHERE mail_type LIKE 'subdom\\_%' GROUP BY sub_id
            ) AS t4 ON (t1.subdomain_id = t4.sub_id)
            WHERE t1.subdomain_id = ?
        ",
        $subdomainId
    );
    unless (ref $rdata eq 'HASH') {
        error( $rdata );
        return 1;
    }
    unless ($rdata->{$subdomainId}) {
        error( sprintf( 'Subdomain with ID %s has not been found or is in an inconsistent state', $subdomainId ) );
        return 1;
    }

    %{$self} = (%{$self}, %{$rdata->{$subdomainId}});
    0;
}

=item _getData($action)

 Data provider method for servers and packages

 Param string $action Action
 Return hashref Reference to a hash containing data, die on failure

=cut

sub _getData
{
    my ($self, $action) = @_;

    $self->{'_data'} = do {
        my $httpd = Servers::httpd->factory();
        my $groupName = my $userName = $main::imscpConfig{'SYSTEM_USER_PREFIX'}.
            ($main::imscpConfig{'SYSTEM_USER_MIN_UID'} + $self->{'domain_admin_id'});
        my $homeDir = File::Spec->canonpath( "$main::imscpConfig{'USER_WEB_DIR'}/$self->{'user_home'}" );
        my $webDir = File::Spec->canonpath( "$homeDir/$self->{'subdomain_mount'}" );
        my $documentRoot = File::Spec->canonpath( "$webDir/$self->{'subdomain_document_root'}" );
        my $db = iMSCP::Database->factory();
        my $confLevel = $httpd->{'phpConfig'}->{'PHP_CONFIG_LEVEL'};
        $confLevel = $confLevel =~ /^per_(?:user|domain)$/ ? 'dmn' : 'sub';

        my $phpiniMatchId = $confLevel eq 'dmn' ? $self->{'domain_id'} : $self->{'subdomain_id'};
        my $phpini = $db->doQuery(
            'domain_id', 'SELECT * FROM php_ini WHERE domain_id = ? AND domain_type = ?', $phpiniMatchId, $confLevel
        );
        ref $phpini eq 'HASH' or die( $phpini );

        my $certData = $db->doQuery(
            'domain_id', 'SELECT * FROM ssl_certs WHERE domain_id = ? AND domain_type = ? AND status = ?',
            $self->{'subdomain_id'}, 'sub', 'ok'
        );
        ref $certData eq 'HASH' or die( $certData );

        my $haveCert = (
            $certData->{$self->{'subdomain_id'}}
            && -f "$main::imscpConfig{'GUI_ROOT_DIR'}/data/certs/$self->{'subdomain_name'}.$self->{'user_home'}.pem"
        );
        my $allowHSTS = ($haveCert && $certData->{$self->{'subdomain_id'}}->{'allow_hsts'} eq 'on');
        my $hstsMaxAge = $allowHSTS ? $certData->{$self->{'subdomain_id'}}->{'hsts_max_age'} : '';
        my $hstsIncludeSubDomains = ($allowHSTS && $certData->{$self->{'subdomain_id'}}->{'hsts_include_subdomains'} eq 'on')
            ? '; includeSubDomains' : '';

        {
            ACTION                  => $action,
            STATUS                  => $self->{'subdomain_status'},
            BASE_SERVER_VHOST       => $main::imscpConfig{'BASE_SERVER_VHOST'},
            BASE_SERVER_IP          => $main::imscpConfig{'BASE_SERVER_IP'},
            BASE_SERVER_PUBLIC_IP   => $main::imscpConfig{'BASE_SERVER_PUBLIC_IP'},
            DOMAIN_ADMIN_ID         => $self->{'domain_admin_id'},
            DOMAIN_NAME             => $self->{'subdomain_name'}.'.'.$self->{'user_home'},
            DOMAIN_NAME_UNICODE     => decode_utf8( idn_to_unicode( $self->{'subdomain_name'}.'.'.$self->{'user_home'}, 'utf-8' ) ),
            DOMAIN_IP               => $self->{'ip_number'},
            DOMAIN_TYPE             => 'sub',
            PARENT_DOMAIN_NAME      => $self->{'user_home'},
            ROOT_DOMAIN_NAME        => $self->{'user_home'},
            HOME_DIR                => $homeDir,
            WEB_DIR                 => $webDir,
            MOUNT_POINT             => $self->{'subdomain_mount'},
            DOCUMENT_ROOT           => $documentRoot,
            SHARED_MOUNT_POINT      => $self->_sharedMountPoint(),
            PEAR_DIR                => $httpd->{'phpConfig'}->{'PHP_PEAR_DIR'},
            TIMEZONE                => $main::imscpConfig{'TIMEZONE'},
            USER                    => $userName,
            GROUP                   => $groupName,
            PHP_SUPPORT             => $self->{'domain_php'},
            CGI_SUPPORT             => $self->{'domain_cgi'},
            WEB_FOLDER_PROTECTION   => $self->{'web_folder_protection'},
            SSL_SUPPORT             => $haveCert,
            HSTS_SUPPORT            => $allowHSTS,
            HSTS_MAX_AGE            => $hstsMaxAge,
            HSTS_INCLUDE_SUBDOMAINS => $hstsIncludeSubDomains,
            BWLIMIT                 => $self->{'domain_traffic_limit'},
            ALIAS                   => $userName.'sub'.$self->{'subdomain_id'},
            FORWARD                 => $self->{'subdomain_url_forward'} || 'no',
            FORWARD_TYPE            => $self->{'subdomain_type_forward'} || '',
            FORWARD_PRESERVE_HOST   => $self->{'subdomain_host_forward'} || 'Off',
            DISABLE_FUNCTIONS       => $phpini->{$phpiniMatchId}->{'disable_functions'} // 'exec,passthru,phpinfo,popen,proc_open,show_source,shell,shell_exec,symlink,system',
            MAX_EXECUTION_TIME      => $phpini->{$phpiniMatchId}->{'max_execution_time'} // 30,
            MAX_INPUT_TIME          => $phpini->{$phpiniMatchId}->{'max_input_time'} // 60,
            MEMORY_LIMIT            => $phpini->{$phpiniMatchId}->{'memory_limit'} // 128,
            ERROR_REPORTING         => $phpini->{$phpiniMatchId}->{'error_reporting'} || 'E_ALL & ~E_DEPRECATED & ~E_STRICT',
            DISPLAY_ERRORS          => $phpini->{$phpiniMatchId}->{'display_errors'} || 'off',
            POST_MAX_SIZE           => $phpini->{$phpiniMatchId}->{'post_max_size'} // 8,
            UPLOAD_MAX_FILESIZE     => $phpini->{$phpiniMatchId}->{'upload_max_filesize'} // 2,
            ALLOW_URL_FOPEN         => $phpini->{$phpiniMatchId}->{'allow_url_fopen'} || 'off',
            PHP_FPM_LISTEN_PORT     => ($phpini->{$phpiniMatchId}->{'id'} // 0) - 1,
            EXTERNAL_MAIL           => $self->{'external_mail'},
            MAIL_ENABLED            => ($self->{'external_mail'} eq 'off' && ($self->{'mail_on_domain'} || $self->{'domain_mailacc_limit'} >= 0))
        }
    } unless %{$self->{'_data'}};

    $self->{'_data'};
}

=item _sharedMountPoint()

 Does this subdomain share mount point with another domain?

 Return bool, die on failure

=cut

sub _sharedMountPoint
{
    my $self = shift;

    my $regexp = "^$self->{'subdomain_mount'}(/.*|\$)";
    my $db = iMSCP::Database->factory()->getRawDb();
    my ($nbSharedMountPoints) = $db->selectrow_array(
        "
            SELECT COUNT(mount_point) AS nb_mount_points FROM (
                SELECT alias_mount AS mount_point FROM domain_aliasses
                WHERE domain_id = ? AND alias_status NOT IN ('todelete', 'ordered') AND alias_mount RLIKE ?
                UNION
                SELECT subdomain_mount AS mount_point FROM subdomain
                WHERE subdomain_id <> ? AND domain_id = ? AND subdomain_status <> 'todelete' AND subdomain_mount RLIKE ?
                UNION
                SELECT subdomain_alias_mount AS mount_point FROM subdomain_alias
                WHERE subdomain_alias_status <> 'todelete'
                AND alias_id IN (SELECT alias_id FROM domain_aliasses WHERE domain_id = ?)
                AND subdomain_alias_mount RLIKE ?
            ) AS tmp
        ",
        undef, $self->{'domain_id'}, $regexp, $self->{'subdomain_id'}, $self->{'domain_id'}, $regexp,
        $self->{'domain_id'}, $regexp
    );

    die( $db->errstr ) if $db->err;
    ($nbSharedMountPoints || $self->{'subdomain_mount'} eq '/');
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
