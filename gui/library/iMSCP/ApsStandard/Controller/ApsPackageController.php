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

namespace iMSCP\ApsStandard\Controller;

use iMSCP\ApsStandard\Entity\ApsPackage;
use iMSCP\ApsStandard\Service\ApsPackageService;
use iMSCP_Authentication as Authentication;
use JMS\Serializer\Serializer;

/**
 * Class ApsPackageController
 * @package iMSCP\ApsStandard\Controller
 */
class ApsPackageController extends ApsAbstractController
{
	/**
	 * @var ApsPackageService
	 */
	protected $packageService;

	/**
	 * Constructor
	 *
	 * @param Serializer $serializer
	 * @param ApsPackageService $packageService
	 */
	public function __construct(Serializer $serializer, ApsPackageService $packageService)
	{
		parent::__construct($serializer);
		$this->packageService = $packageService;
	}

	/**
	 * {@inheritdoc}
	 */
	public function handleRequest()
	{
		switch ($_SERVER['REQUEST_METHOD']) {
			case 'GET':
				if (!isset($_GET['id'])) {
					$this->index();
				} else {
					$this->showDetails(intval($_GET['id']));
				}
				break;
			case 'PUT':
				$this->changeStatus();
				break;
			case 'POST':
				$this->updateIndex();
		}

		$this->sendResponse(400);
	}

	/**
	 * Lists all packages
	 *
	 * @void
	 */
	protected function index()
	{
		try {
			$this->sendResponse(200, $this->packageService->getPackages());
		} catch (\Exception $e) {
			write_log(sprintf('Could not get package list: %s', $e->getMessage()), E_USER_ERROR);
			if (Authentication::getInstance()->getIdentity()->admin_type === 'admin') {
				$this->sendResponse(500, array('message' => tr('Could not get package list: %s', $e->getMessage())));
			} else {
				$this->sendResponse(500, array('message' => tr('Could not get package list. Please contact your reseller.')));
			}
		}
	}

	/**
	 * Show package details
	 *
	 * @param $packageId
	 */
	protected function showDetails($packageId)
	{
		try {
			$packageDetails = $this->packageService->getPackageDetails($packageId);
			if (!$packageDetails) {
				$this->sendResponse(404);
			}

			$this->sendResponse(200, $packageDetails);
		} catch (\Exception $e) {
			write_log(sprintf('Could not get package details: %s', $e->getMessage()), E_USER_ERROR);
			if (Authentication::getInstance()->getIdentity()->admin_type === 'admin') {
				$this->sendResponse(500, array('message' => tr('Could not get package details: %s', $e->getMessage())));
			} else {
				$this->sendResponse(500, array('message' => tr('Could not get package details. Please contact your reseller.')));
			}
		}
	}

	/**
	 * Change package status
	 *
	 * @return void
	 */
	protected function changeStatus()
	{
		try {
			if (Authentication::getInstance()->getIdentity()->admin_type !== 'admin') {
				$this->sendResponse(403); // Only administrators can change package status
			}

			if (($payload = @file_get_contents('php://input')) !== false) {
				/** @var ApsPackage $package */
				$package = $this->getSerializer()->deserialize($payload, 'iMSCP\ApsStandard\Entity\ApsPackage', 'json');
				if (count($this->getValidator()->validate($package)) == 0) {
					if ($this->packageService->updatePackageStatus($package->getId(), $package->getStatus())) {
						$this->sendResponse(204);
					}
				}
			}

			$this->sendResponse(400);
		} catch (\Exception $e) {
			write_log(sprintf('Could not change package status: %s', $e->getMessage()), E_USER_ERROR);
			$this->sendResponse(500, array('message' => tr('Could not change package status: %s', $e->getMessage())));
		}
	}

	/**
	 * Update package index
	 *
	 * @return void
	 */
	protected function updateIndex()
	{
		try {
			if (Authentication::getInstance()->getIdentity()->admin_type !== 'admin') {
				$this->sendResponse(403);
			}

			$this->packageService->updatePackageIndex();
			$this->sendResponse(200, array('message' => tr('Package index has been updated.')));
		} catch (\Exception $e) {
			write_log(sprintf('Could not update package index: %s', $e->getMessage()), E_USER_ERROR);
			$this->sendResponse(500, array('message' => tr('Could not update package index: %s', $e->getMessage())));
		}
	}
}
