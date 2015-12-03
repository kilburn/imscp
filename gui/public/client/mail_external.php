<?php
/**
 * i-MSCP - internet Multi Server Control Panel
 * Copyright (C) 2010-2015 by Laurent Declercq <l.declercq@nuxwin.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

/***********************************************************************************************************************
 * Functions
 */

/**
 * Generate an external mail server item
 *
 * @access private
 * @param iMSCP\Core\Template\TemplateEngine $tpl Template instance
 * @param string $externalMail Status of external mail for the domain
 * @param int $domainId Domain id
 * @param string $domainName Domain name
 * @param string $status Item status
 * @param string $type Domain type (normal for domain or alias for domain alias)
 * @return void
 */
function _client_generateItem($tpl, $externalMail, $domainId, $domainName, $status, $type)
{
	$cfg = \iMSCP\Core\Application::getInstance()->getConfig();
	$idnDomainName = decode_idna($domainName);
	$statusOk = 'ok';
	$queryParam = urlencode("$domainId;$type");
	$htmlDisabled = $cfg['HTML_DISABLED'];

	if ($externalMail == 'off') {
		$tpl->assign(
			array(
				'DOMAIN' => $idnDomainName,
				'STATUS' => ($status == $statusOk) ? tr('Deactivated') : translate_dmn_status($status),
				'DISABLED' => $htmlDisabled,
				'ITEM_TYPE' => $type,
				'ITEM_ID' => $domainId,
				'ACTIVATE_URL' => ($status == $statusOk) ? "mail_external_add.php?item=$queryParam" : '#',
				'TR_ACTIVATE' => ($status == $statusOk) ? tr('Activate') : tr('N/A'),
				'EDIT_LINK' => '',
				'DEACTIVATE_LINK' => ''
			)
		);

		$tpl->parse('ACTIVATE_LINK', 'activate_link');
	} elseif (in_array($externalMail, array('domain', 'wildcard', 'filter'))) {
		$tpl->assign(
			array(
				'DOMAIN' => $idnDomainName,
				'STATUS' => ($status == $statusOk) ? tr('Activated') : translate_dmn_status($status),
				'DISABLED' => ($status == $statusOk) ? '' : $htmlDisabled,
				'ITEM_TYPE' => $type,
				'ITEM_ID' => $domainId,
				'ACTIVATE_LINK' => '',
				'TR_EDIT' => ($status == $statusOk) ? tr('Edit') : tr('N/A'),
				'EDIT_URL' => ($status == $statusOk) ? "mail_external_edit.php?item=$queryParam" : '#',
				'TR_DEACTIVATE' => ($status == $statusOk) ? tr('Deactivate') : tr('N/A'),
				'DEACTIVATE_URL' => ($status == $statusOk) ? "mail_external_delete.php?item=$queryParam" : '#'
			)
		);

		$tpl->parse('EDIT_LINK', 'edit_link');
		$tpl->parse('DEACTIVATE_LINK', 'deactivate_link');
	}
}

/**
 * Generate external mail server item list
 *
 * @access private
 * @param iMSCP\Core\Template\TemplateEngine $tpl Template engine
 * @param int $domainId Domain id
 * @param string $domainName Domain name
 * @return void
 */
function _client_generateItemList($tpl, $domainId, $domainName)
{
	$stmt = exec_query('SELECT domain_status, external_mail FROM domain WHERE domain_id = ?', $domainId);
	$data = $stmt->fetch(PDO::FETCH_ASSOC);

	_client_generateItem($tpl, $data['external_mail'], $domainId, $domainName, $data['domain_status'], 'normal');

	$tpl->parse('ITEM', '.item');

	$stmt = exec_query(
		'SELECT alias_id, alias_name, alias_status, external_mail FROM domain_aliasses WHERE domain_id = ?',
		$domainId
	);

	if ($stmt->rowCount()) {
		while ($data = $stmt->fetch(PDO::FETCH_ASSOC)) {
			_client_generateItem(
				$tpl, $data['external_mail'], $data['alias_id'], $data['alias_name'], $data['alias_status'], 'alias'
			);

			$tpl->parse('ITEM', '.item');
		}
	}
}

/**
 * Generates view
 *
 * @param iMSCP\Core\Template\TemplateEngine $tpl
 * @return void
 */
function client_generateView($tpl)
{
	\iMSCP\Core\Application::getInstance()->getEventManager()->attach(\iMSCP\Core\Events::onGetJsTranslations, function($e) {
		/** @var \Zend\EventManager\Event  $e */
		$translations = $e->getParam('translations');
		$translations['core']['datatable'] = getDataTablesPluginTranslations(false);
		$translations['core']['deactivate_message'] = tr(
			"Are you sure you want to deactivate the external mail server(s) for the '%s' domain?", true, '%s'
		);
	});

	$tpl->assign(
		array(
			'TR_PAGE_TITLE' => tr('Client / Email / External Mail Server'),
			'TR_DOMAIN' => tr('Domain'),
			'TR_STATUS' => tr('Status'),
			'TR_ACTION' => tr('Action'),
			'TR_DEACTIVATE_SELECTED_ITEMS' => tr('Deactivate selected items'),
			'TR_CANCEL' => tr('Cancel')
		)
	);

	$domainProps = get_domain_default_props($_SESSION['user_id']);
	$domainId = $domainProps['domain_id'];
	$domainName = $domainProps['domain_name'];
	_client_generateItemList($tpl, $domainId, $domainName);
}

/***********************************************************************************************************************
 * Main
 */

// Include core library
require_once 'imscp-lib.php';

\iMSCP\Core\Application::getInstance()->getEventManager()->trigger(\iMSCP\Core\Events::onClientScriptStart);

check_login('user');

if (customerHasFeature('external_mail')) {
	$tpl = new \iMSCP\Core\Template\TemplateEngine();
	$tpl->define_dynamic(
		array(
			'layout' => 'shared/layouts/ui.tpl',
			'page' => 'client/mail_external.tpl',
			'page_message' => 'layout',
			'item' => 'page',
			'activate_link' => 'item',
			'edit_link' => 'item',
			'deactivate_link' => 'item'
		)
	);

	generateNavigation($tpl);
	client_generateView($tpl);
	generatePageMessage($tpl);

	$tpl->parse('LAYOUT_CONTENT', 'page');
	\iMSCP\Core\Application::getInstance()->getEventManager()->trigger(\iMSCP\Core\Events::onClientScriptEnd, array('templateEngine' => $tpl));
	$tpl->prnt();
	unsetMessages();
} else {
	showBadRequestErrorPage();
}
