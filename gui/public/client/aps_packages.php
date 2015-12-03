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

require '../../application.php';

\iMSCP\Core\Application::getInstance()->getEventManager()->trigger(\iMSCP\Core\Events::onClientScriptStart);
check_login('user');

if (customerHasFeature('aps_standard')) {
	if (is_xhr()) {
		try {
			/** @var \iMSCP\ApsStandard\Controller\ApsPackageController $controller */
			$controller =\iMSCP\Core\Application::getInstance()->getServiceManager()->get('ApsPackageController');
			$controller->handleRequest();
		} catch (\Exception $e) {
			header('Status: 500 Internal Server Error');
		}
		exit;
	}

	$tpl = new \iMSCP\Core\Template\TemplateEngine();
	$tpl->define_dynamic([
		'layout' => 'shared/layouts/ui.tpl',
		'page' => 'assets/angular/aps-standard/aps-package/aps-packages.tpl',
		'page_message' => 'layout',
	]);

	$tpl->assign([
		'TR_PAGE_TITLE' => tohtml(tr('Client / APS Standard / Packages'), 'htmlAttr'),
		'PAGE_MESSAGE' => ''
	]);

	generateNavigation($tpl);

	$tpl->parse('LAYOUT_CONTENT', 'page');
	\iMSCP\Core\Application::getInstance()->getEventManager()->trigger(\iMSCP\Core\Events::onClientScriptEnd, ['templateEngine' => $tpl]);
	$tpl->prnt();
} else {
	showBadRequestErrorPage();
}
