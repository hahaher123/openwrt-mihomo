'use strict';
'require view';
'require poll';
'require rpc';
'require fs';
'require ui';
'require uci';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

function getServiceStatus() {
	return L.resolveDefault(callServiceList('mihomo'), {}).then(function(data) {
		var running = false, pid = null;
		var instances = (data && data['mihomo'] && data['mihomo']['instances']) || {};

		Object.keys(instances).forEach(function(name) {
			var inst = instances[name];

			if (inst && inst['running']) {
				running = true;
				pid = inst['pid'] || pid;
			}
		});

		return { running: running, pid: pid };
	});
}

function isEnabled() {
	return uci.load('mihomo').then(function() {
		return uci.get('mihomo', 'main', 'enabled') == '1';
	});
}

function getVersion() {
	return L.resolveDefault(fs.exec('/usr/bin/mihomo', [ '-v' ]), null).then(function(res) {
		return (res && res.stdout) ? res.stdout.split('\n')[0].trim() : null;
	});
}

function getLog() {
	return L.resolveDefault(fs.exec('/sbin/logread', [ '-l', '50', '-e', 'mihomo' ]), null).then(function(res) {
		return (res && res.stdout && res.stdout.trim()) ? res.stdout.trim() : null;
	});
}

return view.extend({
	handleServiceAction: function(action, ev) {
		return fs.exec('/etc/init.d/mihomo', [ action ]).then(function(res) {
			if (res && res.code != 0)
				ui.addNotification(null, E('p', _('执行 %s 失败 (退出码: %s)').format(action, String(res.code))), 'error');
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('执行 %s 失败: %s').format(action, String(e.message || e))), 'error');
		});
	},

	load: function() {
		return Promise.all([ getServiceStatus(), isEnabled(), getVersion() ]);
	},

	render: function(data) {
		var self = this;
		var status = data[0] || { running: false, pid: null };
		var enabled = !!data[1];
		var version = data[2];

		var statusBadge = E('span', { 'class': 'label' }, E('em', [ _('加载中…') ]));
		var pidEl = E('span', {}, [ '-' ]);
		var enabledEl = E('span', {}, [ '-' ]);

		var updateStatus = function(s) {
			statusBadge.className = 'label ' + (s.running ? 'label-success' : 'label-important');
			statusBadge.textContent = s.running ? _('运行中') : _('未运行');
			pidEl.textContent = (s.running && s.pid) ? String(s.pid) : '-';
		};

		updateStatus(status);
		enabledEl.textContent = enabled ? _('已启用') : _('未启用 (请在运行参数页开启)');

		var table = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, [ _('运行状态') ]),
				E('td', { 'class': 'td left' }, [ statusBadge ])
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, [ _('进程 PID') ]),
				E('td', { 'class': 'td left' }, [ pidEl ])
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, [ _('开机自启') ]),
				E('td', { 'class': 'td left' }, [ enabledEl ])
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, [ _('程序版本') ]),
				E('td', { 'class': 'td left' }, [ version || _('未知') ])
			])
		]);

		var button = function(action, label, cls) {
			return E('button', {
				'class': 'btn cbi-button ' + (cls || 'cbi-button-apply'),
				'click': ui.createHandlerFn(self, 'handleServiceAction', action)
			}, [ label ]);
		};

		var buttons = E('div', { 'style': 'margin:1em 0' }, [
			button('start', _('启动')),
			' ',
			button('stop', _('停止'), 'cbi-button-remove'),
			' ',
			button('restart', _('重启'))
		]);

		var logPre = E('pre', {
			'style': 'max-height:400px; overflow:auto; padding:8px; white-space:pre-wrap; word-break:break-all;'
		}, [ _('加载中…') ]);

		poll.add(function() {
			return getServiceStatus().then(function(s) {
				updateStatus(s);

				return getLog().then(function(log) {
					logPre.textContent = log || _('暂无日志 (需在运行参数中开启日志输出)');
				});
			});
		}, 5);

		return E([
			E('h2', [ _('Mihomo 运行状态') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('查看 Mihomo 服务的运行状态并进行启动/停止/重启控制。开机自启请在「运行参数」页修改。')
			]),
			E('div', { 'class': 'cbi-section' }, [ table, buttons ]),
			E('h3', [ _('系统日志 (最近 50 行)') ]),
			logPre
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
