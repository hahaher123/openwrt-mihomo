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
		var raw = (res && res.stdout && res.stdout.trim()) ? res.stdout.trim() : null;
		if (!raw)
			return null;

		return probeRouterTZ().then(function(offsetMin) {
			return formatLogUTC8(raw, offsetMin);
		});
	});
}

// 路由器的 UTC 偏移(分钟)。logread 的行首时间戳是「记录时刻路由器的本地时间」,
// 要换算成东八区必须知道路由器自己的时区。取一次缓存即可。
var ROUTER_TZ_MIN = null;

function probeRouterTZ() {
	if (ROUTER_TZ_MIN !== null)
		return Promise.resolve(ROUTER_TZ_MIN);

	return L.resolveDefault(fs.exec('/bin/date', [ '+%z' ]), null).then(function(res) {
		var m = (res && res.stdout) ? String(res.stdout).trim().match(/^([+-])(\d{2})(\d{2})$/) : null;
		var sign = m ? (m[1] == '-' ? -1 : 1) : 0;

		ROUTER_TZ_MIN = m ? sign * (parseInt(m[2], 10) * 60 + parseInt(m[3], 10)) : 0;
		return ROUTER_TZ_MIN;
	});
}

// busybox logread 行首格式: "Sun Sep 20 10:14:09 2026 daemon.info ..."
// 依此把每行时间戳从路由器本地时间改写成东八区 (UTC+8) 的
// "YYYY-MM-DD HH:MM:SS", 行的其余部分原样保留; 解析不了的行不动。
var LOG_MONTHS = { Jan: 0, Feb: 1, Mar: 2, Apr: 3, May: 4, Jun: 5,
                   Jul: 6, Aug: 7, Sep: 8, Oct: 9, Nov: 10, Dec: 11 };

function formatLogUTC8(text, offsetMin) {
	var pad = function(n) { return (n < 10 ? '0' : '') + n; };

	return text.split('\n').map(function(line) {
		var m = line.match(/^[A-Z][a-z]{2} ([A-Z][a-z]{2})\s+(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})\s(.*)$/);
		if (!m || !(m[1] in LOG_MONTHS))
			return line;

		// 路由器本地时间 -> 真实时刻 -> 东八区墙钟
		var utcMs = Date.UTC(+m[6], LOG_MONTHS[m[1]], +m[2],
			+m[3], +m[4], +m[5]) - offsetMin * 60000;
		var d = new Date(utcMs + 8 * 3600000);

		return '%d-%02d-%02d %02d:%02d:%02d %s'.format(
			d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate(),
			d.getUTCHours(), d.getUTCMinutes(), d.getUTCSeconds(), m[7]);
	}).join('\n');
}

return view.extend({
	handleServiceAction: function(action, ev) {
		var self = this;

		return fs.exec('/etc/init.d/mihomo', [ action ]).then(function(res) {
			if (res && res.code != 0)
				ui.addNotification(null, E('p', _('执行 %s 失败 (退出码: %s)').format(action, String(res.code))), 'error');
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('执行 %s 失败: %s').format(action, String(e.message || e))), 'error');
		}).then(function() {
			// 操作完成后立即刷新状态, 不等下一个轮询周期。启动/重启后服务
			// 要过一两秒才挂上 procd, 所以错开 1.5s 再查; 轮询继续兜底。
			if (self.doRefresh) {
				window.setTimeout(self.doRefresh, 1500);
				window.setTimeout(self.doRefresh, 4000);
			}
		});
	},

	handleToggleEnabled: function(ev) {
		var self = this;
		var next = (uci.get('mihomo', 'main', 'enabled') == '1') ? '0' : '1';

		uci.set('mihomo', 'main', 'enabled', next);

		return uci.save().then(function() {
			return uci.apply();
		}).then(function() {
			ui.addNotification(null, E('p', next == '1'
				? _('已开启开机自启, 服务将自动启动')
				: _('已关闭开机自启, 正在运行的服务将自动停止')), 'info');

			// uci 已提交, 立即刷新开关磁贴
			if (self.doRefresh)
				self.doRefresh();
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('修改开机自启失败: %s').format(String(e.message || e))), 'error');
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

		var toggleBtn = E('button', {
			'class': 'btn cbi-button cbi-button-positive',
			'style': 'margin-top:8px; font-size:0.95em; padding:3px 14px;',
			'click': ui.createHandlerFn(self, 'handleToggleEnabled')
		}, [ '' ]);

		var updateEnabled = function(en) {
			setTile(tileEnabled, en ? _('已启用') : _('未启用'), en ? '#2e9e44' : '#b06000');
			toggleBtn.className = 'btn cbi-button ' + (en ? 'cbi-button-negative' : 'cbi-button-positive');
			toggleBtn.textContent = en ? _('关闭自启') : _('开启自启');
		};

		updateEnabled(enabled);
		setTile(tileVersion, version || _('未知'));
		tileEnabled.appendChild(toggleBtn);

		var tiles = E('div', {
			'style': 'display:flex; gap:12px; flex-wrap:wrap; margin-bottom:14px;'
		}, [ tileEnabled, tileVersion ]);

		/* -- 控制按钮 -- */
		var curStatus = { running: false };
		var pendingAction = null;       // 正在执行的动作 (尚未被 doRefresh 确认)
		var optimisticRunning = null;   // 点击后立即翻转的目标状态 (启动/停止)

		var startStopBtn = E('button', {
			'class': 'btn cbi-button cbi-button-positive',
			'style': 'font-size:1.1em; padding:8px 22px;',
			'click': ui.createHandlerFn(self, function() {
				var action = (optimisticRunning != null ? optimisticRunning : curStatus.running) ? 'stop' : 'start';

				pendingAction = action;
				optimisticRunning = (action == 'start');
				applyButtons();          // 按下启动后按钮立即变成「停止」

				return self.handleServiceAction(action);
			})
		}, [ '' ]);

		var restartBtn = E('button', {
			'class': 'btn cbi-button cbi-button-apply',
			'style': 'font-size:1.1em; padding:8px 22px;',
			'click': ui.createHandlerFn(self, function() {
				pendingAction = 'restart';
				applyButtons();

				return self.handleServiceAction('restart');
			})
		}, [ '' ]);

		// 按钮显示统一从这里刷新: 乐观翻转 (点击瞬间) 与真实状态确认 (doRefresh)
		// 都走这一条路, 保证按钮始终与最近一次已知的服务状态一致。
		var applyButtons = function() {
			var running = (optimisticRunning != null) ? optimisticRunning : curStatus.running;
			var busy = (pendingAction != null);

			startStopBtn.className = 'btn cbi-button ' + (running ? 'cbi-button-remove' : 'cbi-button-positive');
			startStopBtn.textContent = running ? _('■ 停止') : _('▶ 启动');

			restartBtn.textContent = _('↻ 重启');

			// 动作执行到状态确认之间禁用按钮, 防止连点; 未运行时重启无意义
			startStopBtn.disabled = busy;
			restartBtn.disabled = busy || !running;
		};

		applyButtons();

		var buttons = E('div', { 'style': 'margin:4px 0 16px 0' }, [
			startStopBtn,
			' ',
			restartBtn
		]);

		/* -- 日志 -- */
		var logPre = E('pre', {
			'style': 'max-height:400px; overflow:auto; padding:10px; white-space:pre-wrap; word-break:break-all; background:#f6f6f6; border:1px solid #e2e2e2; border-radius:8px; font-size:0.9em;'
		}, [ _('加载中…') ]);

		// 状态刷新的唯一入口: 横幅 / 启停按钮 / 开机自启磁贴 / 日志全部在这里
		// 更新。轮询周期性调用, 操作完成后也会立即调用 (见 handleServiceAction /
		// handleToggleEnabled), 保证改动后不用手动刷新页面。
		this.doRefresh = function() {
			return getServiceStatus().then(function(s) {
				// 以真实状态为准: 清掉点击瞬间的乐观翻转与待确认标记
				curStatus = s || { running: false };
				pendingAction = null;
				optimisticRunning = null;

				applyButtons();
				updateBanner(curStatus);

				return isEnabled().then(function(en) {
					updateEnabled(en);

					return getLog().then(function(log) {
						logPre.textContent = log || _('暂无日志 (需在运行参数中开启日志输出)');
					});
				});
			});
		};

		poll.add(this.doRefresh, 5);

		return E([
			E('h2', [ _('Mihomo 运行状态') ]),
			banner,
			tiles,
			buttons,
			E('h3', [ _('系统日志 (最近 50 行, 时间为东八区 UTC+8)') ]),
			logPre
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
