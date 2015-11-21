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

namespace iMSCP\ApsStandard;

use iMSCP\ApsStandard\Controller\ApsInstanceController;
use iMSCP_Events_Aggregator as EventManager;
use iMSCP_Events as Events;
use iMSCP_pTemplate as TemplateEngine;
use iMSCP_Registry as Registry;

require 'imscp-lib.php';

$eventManager = EventManager::getInstance();
$eventManager->dispatch(Events::onClientScriptStart);
check_login('user');

if (customerHasFeature('aps_standard')) {
	if (is_xhr()) {
		try {
			/** @var ApsInstanceController $controller */
			$controller = Registry::get('ServiceManager')->get('ApsInstanceController');
			$controller->handleRequest();
		} catch (\Exception $e) {
			header('Status: 500 Internal Server Error');
		}
		exit;
	}

	$tpl = new TemplateEngine();
	$tpl->define_dynamic(array(
		'layout' => 'shared/layouts/ui.tpl',
		'page' => 'assets/angular/aps-standard/aps-instance/aps-instances.tpl',
		'page_message' => 'layout'
	));

	$tpl->assign(array(
		'TR_PAGE_TITLE' => tohtml(tr('Client / APS Standard / Application instances'), 'htmlAttr'),
	));

	generateNavigation($tpl);
	generatePageMessage($tpl);

	$tpl->parse('LAYOUT_CONTENT', 'page');
	$eventManager->dispatch(Events::onClientScriptEnd, array('templateEngine' => $tpl));
	$tpl->prnt();
} else {
	showBadRequestErrorPage();
}
