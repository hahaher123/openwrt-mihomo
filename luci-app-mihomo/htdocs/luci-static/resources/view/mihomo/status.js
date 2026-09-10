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

		/* -- 大号状态横幅 -- */
		var bannerIcon = E('span', {
			'style': 'display:inline-block; width:16px; height:16px; border-radius:50%; background:#fff; margin-right:14px; vertical-align:middle; box-shadow:0 0 0 4px rgba(255,255,255,0.35);'
		});

		var bannerText = E('span', {
			'style': 'font-size:1.9em; font-weight:700; vertical-align:middle;'
		}, [ '…' ]);

		var bannerSub = E('div', {
			'style': 'font-size:1.05em; opacity:0.9; margin-top:4px; text-align:right;'
		}, [ '' ]);

		var banner = E('div', {
			'style': 'display:flex; align-items:center; justify-content:space-between; padding:20px 26px; border-radius:10px; margin:6px 0 14px 0; color:#fff; background:#9e9e9e; box-shadow:0 2px 6px rgba(0,0,0,0.18);'
		}, [
			E('div', {}, [ bannerIcon, bannerText ]),
			bannerSub
		]);

		var updateBanner = function(s) {
			if (s.running) {
				banner.style.background = '#2e9e44';
				bannerText.textContent = _('运行中');
				bannerSub.textContent = s.pid ? 'PID: %s'.format(String(s.pid)) : '';
			} else {
				banner.style.background = '#d64541';
				bannerText.textContent = _('未运行');
				bannerSub.textContent = _('服务未在运行, 点击下方「启动」');
			}
		};

		updateBanner(status);

		/* -- 信息磁贴 -- */
		var tile = function(title) {
			return E('div', {
				'style': 'flex:1; background:#fff; border:1px solid #e2e2e2; border-radius:8px; padding:12px 18px; min-width:140px;'
			}, [
				E('div', { 'style': 'font-size:0.85em; color:#888; margin-bottom:4px;' }, [ title ]),
				E('div', { 'class': 'tile-value', 'style': 'font-size:1.25em; font-weight:600; color:#333;' }, [ '-' ])
			]);
		};

		var tileEnabled = tile(_('开机自启'));
		var tileVersion = tile(_('程序版本'));

		var setTile = function(t, v, color) {
			var el = t.querySelector('.tile-value');
			el.textContent = v;

			if (color)
				el.style.color = color;
			else
				el.style.color = '#333';
		};

		setTile(tileEnabled, enabled ? _('已启用') : _('未启用'), enabled ? '#2e9e44' : '#b06000');
		setTile(tileVersion, version || _('未知'));

		var tiles = E('div', {
			'style': 'display:flex; gap:12px; flex-wrap:wrap; margin-bottom:14px;'
		}, [ tileEnabled, tileVersion ]);

		/* -- 控制按钮 -- */
		var button = function(action, label, cls) {
			return E('button', {
				'class': 'btn cbi-button ' + (cls || 'cbi-button-apply'),
				'style': 'font-size:1.1em; padding:8px 22px;',
				'click': ui.createHandlerFn(self, 'handleServiceAction', action)
			}, [ label ]);
		};

		var buttons = E('div', { 'style': 'margin:4px 0 16px 0' }, [
			button('start', _('▶ 启动')),
			' ',
			button('stop', _('■ 停止'), 'cbi-button-remove'),
			' ',
			button('restart', _('↻ 重启'))
		]);

		/* -- 日志 -- */
		var logPre = E('pre', {
			'style': 'max-height:400px; overflow:auto; padding:10px; white-space:pre-wrap; word-break:break-all; background:#f6f6f6; border:1px solid #e2e2e2; border-radius:8px; font-size:0.9em;'
		}, [ _('加载中…') ]);

		poll.add(function() {
			return getServiceStatus().then(function(s) {
				updateBanner(s);

				return isEnabled().then(function(en) {
					setTile(tileEnabled, en ? _('已启用') : _('未启用'), en ? '#2e9e44' : '#b06000');

					return getLog().then(function(log) {
						logPre.textContent = log || _('暂无日志 (需在运行参数中开启日志输出)');
					});
				});
			});
		}, 5);

		return E([
			E('h2', [ _('Mihomo 运行状态') ]),
			banner,
			tiles,
			buttons,
			E('h3', [ _('系统日志 (最近 50 行)') ]),
			logPre
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
