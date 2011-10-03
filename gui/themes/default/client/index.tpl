<!-- INCLUDE "header.tpl" -->
<body>
	<div class="header">
		{MAIN_MENU}
		<div class="logo">
			<img src="{ISP_LOGO}" alt="i-MSCP logo" />
		</div>
	</div>
	<div class="location">
		<div class="location-area">
			<h1 class="general">{TR_MENU_GENERAL_INFORMATION}</h1>
		</div>
		<ul class="location-menu">
			<!-- BDP: logged_from -->
			<li><a class="backadmin" href="change_user_interface.php?action=go_back">{YOU_ARE_LOGGED_AS}</a></li>
			<!-- EDP: logged_from -->
			<li><a class="logout" href="../index.php?logout">{TR_MENU_LOGOUT}</a></li>
		</ul>
		<ul class="path">
			<li><a href="index.php">{TR_MENU_GENERAL_INFORMATION}</a></li>
			<li><a href="index.php">{TR_LMENU_OVERVIEW}</a></li>
		</ul>
	</div>
	<div class="left_menu">{MENU}</div>
	<div class="body">
		<h2 class="general"><span>{TR_TITLE_GENERAL_INFORMATION}</span></h2>

		<!-- BDP: page_message -->
		<div class="{MESSAGE_CLS}">{MESSAGE}</div>
		<!-- EDP: page_message -->

		<!-- BDP: msg_entry -->
		<div class="warning">{TR_NEW_MSGS}</div>
		<!-- EDP: msg_entry -->

		<table>
			<tr>
				<th colspan="2">{TR_DOMAIN_DATA}</th>
			</tr>
			<tr>
				<td style="width: 300px;">{TR_ACCOUNT_NAME} / {TR_MAIN_DOMAIN}</td>
				<td>{ACCOUNT_NAME}</td>
			</tr>
			<!-- BDP: alternative_domain_url -->
			<tr>
				<td>{TR_DMN_TMP_ACCESS}</td>
				<td><a id="dmn_tmp_access" href="{DOMAIN_ALS_URL}" target="_blank">{DOMAIN_ALS_URL}</a></td>
			</tr>
			<!-- EDP: alternative_domain_url -->
			<tr>
				<td>{TR_DOMAIN_EXPIRE}</td>
				<td>{DMN_EXPIRES} {DMN_EXPIRES_DATE}</td>
			</tr>
		</table>
		<br />
		<table>
			<tr>
				<th  style="width: 300px;">{TR_FEATURES}</th>
				<th>{TR_STATUS}</th>
			</tr>
			<!-- BDP: t_alias_support -->
			<tr>
				<td>{TR_DOMAIN_ALIASES}</td>
				<td>{DOMAIN_ALIASES}</td>
			</tr>
			<!--EDP: t_alias_support -->
			<!-- BDP: t_sdm_support -->
			<tr>
				<td>{TR_SUBDOMAINS}</td>
				<td>{SUBDOMAINS}</td>
			</tr>
			<!--EDP: t_sdm_support -->
			<!-- BDP: t_mails_support -->
			<tr>
				<td>{TR_MAIL_ACCOUNTS}</td>
				<td>{MAIL_ACCOUNTS}</td>
			</tr>
			<!--EDP: t_mails_support -->
			<tr>
				<td>{TR_FTP_ACCOUNTS}</td>
				<td>{FTP_ACCOUNTS}</td>
			</tr>
			<!-- BDP: t_sdm_support -->
			<tr>
				<td>{TR_SQL_DATABASES}</td>
				<td>{SQL_DATABASES}</td>
			</tr>
			<tr>
				<td>{TR_SQL_USERS}</td>
				<td>{SQL_USERS}</td>
			</tr>
			<!--EDP: t_sdm_support -->

			<!-- BDP: t_php_support -->
			<tr>
				<td>{TR_PHP_SUPPORT}</td>
				<td>{PHP_SUPPORT}</td>
			</tr>
			<!-- EDP: t_php_support -->
			<!-- BDP: t_cgi_support -->
			<tr>
				<td>{TR_CGI_SUPPORT}</td>
				<td>{CGI_SUPPORT}</td>
			</tr>
			<!-- EDP: t_cgi_support -->


			<!-- BDP: t_software_allowed -->
			<tr>
				<td>{SW_ALLOWED}</td>
				<td>{SW_MSG}</td>
			</tr>
			<!-- EDP: t_software_allowed -->

		</table>
		<h2 class="traffic"><span>{TR_TRAFFIC_USAGE}</span></h2>
		<!-- BDP: traff_warn -->
		<div class="warning">{TR_TRAFFIC_WARNING}</div>
		<!-- EDP: traff_warn -->
		{TRAFFIC_USAGE_DATA}
		<div class="graph"><span style="width:{TRAFFIC_PERCENT}%">&nbsp;</span></div>
		<h2 class="diskusage"><span>{TR_DISK_USAGE}</span></h2>
		<!-- BDP: disk_warn -->
		<div class="warning">{TR_DISK_WARNING}</div>
		<!-- EDP: disk_warn -->
		{DISK_USAGE_DATA}
		<div class="graph"><span style="width:{DISK_PERCENT}%">&nbsp;</span></div>
	</div>
<!-- INCLUDE "footer.tpl" -->
