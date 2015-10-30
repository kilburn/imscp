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

use iMSCP\ApsStandard\Service\ApsPackageService as PackageService;
use iMSCP_Authentication as Auth;
use Symfony\Component\HttpFoundation\JsonResponse as Response;
use Symfony\Component\HttpFoundation\Request;

/**
 * Class ApsPackageController
 * @package iMSCP\ApsStandard\Controller
 */
class ApsPackageController extends ApsAbstractController
{
	/**
	 * @var PackageService
	 */
	protected $packageService;

	/**
	 * Constructor
	 *
	 * @param Request $request
	 * @param Response $response
	 * @param Auth $auth
	 * @param PackageService $packageService
	 */
	public function __construct(Request $request, Response $response, Auth $auth, PackageService $packageService)
	{
		parent::__construct($request, $response, $auth);
		$this->packageService = $packageService;
	}

	/**
	 * {@inheritdoc}
	 */
	public function handleRequest()
	{
		try {
			switch ($this->getRequest()->getMethod()) {
				case Request::METHOD_GET:
					if ($this->getRequest()->query->has('id')) {
						$this->showAction();
					} else {
						$this->indexAction();
					}
					break;
				case Request::METHOD_PUT:
					$this->updateAction();
					break;
				case Request::METHOD_POST:
					$this->updateIndexAction();
					break;
				default:
					$this->getResponse()->setStatusCode(405);
			}
		} catch (\Exception $e) {
			write_log(sprintf('Could not handle request: %s', $e->getMessage()), E_USER_ERROR);
			$this->createResponseFromException($e);
		}

		$this->getResponse()->prepare($this->getRequest())->send();
	}

	/**
	 * List all packages
	 *
	 * @return void
	 */
	protected function indexAction()
	{
		$packages = $this->getSerializer()->serialize($this->getPackageService()->getPackages(), 'json');
		$this->getResponse()->setContent($packages);
	}

	/**
	 * Show package details
	 *
	 * @return void
	 */
	protected function showAction()
	{
		$packageDetails = $this->getPackageService()->getPackageDetails($this->getRequest()->query->getInt('id'));
		$this->getResponse()->setContent($this->getSerializer()->serialize($packageDetails, 'json'));
	}

	/**
	 * Update package
	 *
	 * @throws \Exception
	 * @return void
	 */
	protected function updateAction()
	{
		if ($this->getAuth()->getIdentity()->admin_type !== 'admin') {
			throw new \Exception(tr('Action not allowed.'), 403);
		}

		$packageService = $this->getPackageService();
		$package = $packageService->getPackageFromPayload($this->getRequest()->getContent());
		$packageService->updatePackageStatus($package->getId(), $package->getStatus());
		$this->getResponse()->setStatusCode(204);
	}

	/**
	 * Update package index
	 *
	 * @throws \Exception
	 * @return void
	 */
	protected function updateIndexAction()
	{
		if ($this->getAuth()->getIdentity()->admin_type !== 'admin') {
			throw new \Exception(tr('Action not allowed.'), 403);
		}

		$this->getPackageService()->updatePackageIndex();
		$this->getResponse()->setData(array('message' => tr('Package index has been updated.')));
	}

	/**
	 * Get package service
	 *
	 * @return PackageService
	 */
	protected function getPackageService()
	{
		return $this->packageService;
	}
}