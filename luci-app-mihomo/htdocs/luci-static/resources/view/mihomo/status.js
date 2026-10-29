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

/* -- 运行日志 ---------------------------------------------------------------
 * 数据源是落盘文件 (uci mihomo.main.log_file), 不是 logread: 系统日志是环形
 * 缓冲、会被别的守护进程挤掉、重启即清空, 而且本包默认就不把 mihomo 的进程
 * 输出转发进 syslog。读写都走 /etc/mihomo/log.sh, 好处是不用为可配置的日志路径
 * 在 ACL 里写 file 授权 (rpcd 会对 realpath 后的路径再查一次 ACL, /var -> /tmp
 * 的符号链接很容易踩空), exec 一个固定路径最稳。
 */
var LOG_HELPER = '/etc/mihomo/log.sh';
var LOG_TAIL_LINES = 200;
var LOG_MAX_MIN = 16;
var LOG_MAX_MAX = 102400;

function logExec(args) {
	return L.resolveDefault(fs.exec(LOG_HELPER, args), null).then(function(res) {
		return res || { code: -1, stdout: '', stderr: '' };
	});
}

function readLogStatus() {
	return logExec([ 'status' ]).then(function(res) {
		if (res.code != 0)
			return null;

		var st = { file: '', exists: false, size: 0, max_kb: 0 };

		String(res.stdout || '').split('\n').forEach(function(line) {
			var i = line.indexOf('=');
			if (i <= 0)
				return;

			var k = line.slice(0, i), v = line.slice(i + 1);

			if (k == 'file')
				st.file = v;
			else if (k == 'exists')
				st.exists = (v == '1');
			else if (k == 'size')
				st.size = parseInt(v, 10) || 0;
			else if (k == 'max_kb')
				st.max_kb = parseInt(v, 10) || 0;
		});

		return st.file ? st : null;
	});
}

function readLogTail() {
	return logExec([ 'tail', String(LOG_TAIL_LINES) ]).then(function(res) {
		return (res.code == 0) ? String(res.stdout || '').replace(/\s+$/, '') : '';
	});
}

function formatSize(bytes) {
	var kb = Math.round(bytes / 1024 * 10) / 10;

	return (kb >= 1024) ? '%s MB'.format(String(Math.round(kb / 1024 * 10) / 10))
	                    : '%s KB'.format(String(kb));
}

// 日志面板: 返回 { node, refresh }。refresh 由调用方在节点挂载后调用
// (页面轮询与操作后立即刷新都走这里), 不在函数内部自己拉数据。
function renderLogPanel() {
	var meta = E('div', {
		'style': 'color:#666; font-size:0.9em; margin-bottom:8px;'
	}, [ _('加载中…') ]);

	var pre = E('pre', {
		'style': 'max-height:400px; overflow:auto; padding:10px; white-space:pre-wrap; word-break:break-all; background:#f6f6f6; border:1px solid #e2e2e2; border-radius:8px; font-size:0.9em; margin:0;'
	}, [ _('加载中…') ]);

	var input = E('input', {
		'type': 'number', 'min': String(LOG_MAX_MIN), 'max': String(LOG_MAX_MAX), 'step': '16',
		'style': 'width:7em; text-align:right;', 'placeholder': '1024'
	});

	// 用户正在输入时不要被轮询覆盖掉输入框的值
	var touched = false;

	input.addEventListener('input', function() { touched = true; });

	var notifyError = function(msg) {
		ui.addNotification(null, E('p', [ msg ]), 'error');
	};

	var btnSave = E('button', {
		'class': 'btn cbi-button cbi-button-apply',
		'click': function() {
			var v = String(input.value || '').trim();

			if (!/^\d+$/.test(v) || +v < LOG_MAX_MIN || +v > LOG_MAX_MAX) {
				notifyError(_('上限必须是 %d–%d 之间的整数 (单位 KB)').format(LOG_MAX_MIN, LOG_MAX_MAX));
				return Promise.resolve();
			}

			// 命令行 uci 写入, 不走 uci.apply: 后者会触发服务 reload (stop+start),
			// 改个日志上限不该把代理重启一次。上限只被 log.sh 与 init 消费。
			return logExec([ 'setmax', v ]).then(function(res) {
				if (res.code != 0) {
					notifyError(_('保存失败: %s').format(String(res.stderr || '').trim() || String(res.code)));
					return;
				}

				ui.addNotification(null, E('p', [
					_('日志上限已设为 %s KB, 立即生效 (不会重启服务)').format(v)
				]), 'info');

				touched = false;
				return refresh();
			});
		}
	}, [ _('保存上限') ]);

	var btnClear = E('button', {
		'class': 'btn cbi-button cbi-button-remove',
		'click': function() {
			if (!window.confirm(_('确定清空当前日志? 清空后无法恢复。')))
				return Promise.resolve();

			return logExec([ 'clear' ]).then(function(res) {
				if (res.code != 0) {
					notifyError(_('清空失败: %s').format(String(res.stderr || '').trim() || String(res.code)));
					return;
				}

				return refresh();
			});
		}
	}, [ _('清空日志') ]);

	function refresh() {
		return readLogStatus().then(function(st) {
			if (!st) {
				meta.textContent = _('无法读取日志信息 (%s 不可用)').format(LOG_HELPER);
				pre.textContent = '';
				return;
			}

			meta.textContent = _('日志文件: %s  |  当前大小: %s  |  上限: %s KB').format(
				st.file,
				st.exists ? formatSize(st.size) : _('文件不存在'),
				String(st.max_kb));

			if (!touched)
				input.value = String(st.max_kb);

			return readLogTail().then(function(txt) {
				pre.textContent = txt || _('日志为空。mihomo 运行后写入的内容会出现在这里, 刚启动时可稍等几秒。');
			});
		});
	}

	var node = E('div', {}, [
		E('h3', [ _('Mihomo 运行日志') ]),
		E('div', {
			'style': 'color:#666; font-size:0.9em; margin:-6px 0 10px 0;'
		}, [
			_('进程输出追加写入日志文件, 新登录也能回查以前的内容; 超过上限时只保留最新部分。')
		]),
		meta,
		E('div', {
			'style': 'display:flex; gap:8px; align-items:center; flex-wrap:wrap; margin-bottom:10px;'
		}, [
			E('span', {}, [ _('日志上限') ]),
			input,
			E('span', [ 'KB' ]),
			btnSave,
			btnClear
		]),
		pre
	]);

	return { node: node, refresh: refresh };
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
		var logPanel = renderLogPanel();

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

					return logPanel.refresh();
				});
			});
		};

		poll.add(this.doRefresh, 5);

		return E([
			E('h2', [ _('Mihomo 运行状态') ]),
			banner,
			tiles,
			buttons,
			logPanel.node
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
