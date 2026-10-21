'use strict';
'require view';
'require fs';
'require uci';
'require poll';

//
// Mihomo 后台管理 (external-ui 面板)
//
// 面板文件不在本包里, 由 /etc/mihomo/ui.sh 在运行时下载安装:
//   - 上游 mihomo 自己也会下载 (配置里 external-ui 非空且目标目录为空时,
//     component/updater/update_ui.go 的 AutoDownloadUI), 但它只用
//     external-ui-url, 失败只在日志里写一行, 而且目录非空之后就再也不更新
//     ("UI already exists, skip downloading")。在 LuCI 里手工装一次, 既能
//     换镜像地址, 也能看到到底装了什么。
//   - 下载与解压必须在后台跑: LuCI 的 rpc 超时是 L.env.rpctimeout
//     (luci-base 的 rpc.js: `timeout: (L.env.rpctimeout ?? 20) * 1000`,
//     默认 20 秒, rpc.declare 覆盖不了), 而面板 zip 约 2.5 MB。所以走
//     `ui.sh start` + 轮询 `ui.sh status`, 后者只读几个文件, 毫秒级返回。
//
// 页面本身只读 uci 的 dashboard 一项 (iframe 地址), 不改任何 uci 配置 ——
// 面板装完之后不需要重启 mihomo: /ui 是 http.FileServer 直接读磁盘,
// uiPath 在启动时就已经注册好了。
//

var HELPER = '/etc/mihomo/ui.sh';
var JOB_LOG = '/tmp/mihomo-ui.log';
var URL_KEY = 'mihomo.ui.url';

// kind -> [背景, 左边框, 文字, 前缀]
var KIND = {
	ok:   [ '#e8f5e9', '#2e7d32', '#1b5e20', '✔' ],
	err:  [ '#fdecea', '#c62828', '#b71c1c', '✘' ],
	warn: [ '#fff8e1', '#ef6c00', '#e65100', '▲' ],
	info: [ '#e8f0fe', '#1565c0', '#0d47a1', '➜' ]
};

function joinOutput(res) {
	var out = (res && res.stdout) ? String(res.stdout) : '';
	var err = (res && res.stderr) ? String(res.stderr) : '';

	out = out.replace(/\s+$/, '');
	err = err.replace(/\s+$/, '');

	if (out && err)
		return out + '\n[stderr]\n' + err;

	return out || err;
}

// ui.sh status 的输出是 "KEY: value" 每行一条
function parseKV(text) {
	var kv = {};

	String(text || '').split('\n').forEach(function(line) {
		var m = line.match(/^([A-Z][A-Z0-9_]*):[ \t]*(.*)$/);

		if (m)
			kv[m[1]] = m[2].replace(/\s+$/, '');
	});

	return kv;
}

function fmtSize(n) {
	n = parseInt(n, 10);

	if (isNaN(n) || n < 0)
		return '?';
	if (n < 1024)
		return '%d B'.format(n);
	if (n < 1024 * 1024)
		return '%.1f KB'.format(n / 1024);
	return '%.1f MB'.format(n / (1024 * 1024));
}

// 时间是 epoch 秒, 与设备时区无关; 加 8 小时再取 UTC 字段就是东八区墙钟,
// 与状态页 / 日志显示保持一致。
function fmtUTC8(epoch) {
	var n = parseInt(epoch, 10);

	if (isNaN(n) || n <= 0)
		return '';

	var d = new Date(n * 1000 + 8 * 3600000);

	return '%d-%02d-%02d %02d:%02d'.format(
		d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate(),
		d.getUTCHours(), d.getUTCMinutes());
}

function tailText(text, lines) {
	var arr = String(text || '').replace(/\s+$/, '').split('\n');

	if (arr.length > lines)
		arr = arr.slice(arr.length - lines);

	return arr.join('\n');
}

function loadSavedURL(def) {
	try {
		return window.localStorage.getItem(URL_KEY) || def || '';
	}
	catch (e) {
		return def || '';
	}
}

function saveURL(url) {
	try {
		if (url)
			window.localStorage.setItem(URL_KEY, url);
		else
			window.localStorage.removeItem(URL_KEY);
	}
	catch (e) { /* 隐私模式下 localStorage 可能不可用, 忽略 */ }
}

function bust(u) {
	return u + ((u.indexOf('?') >= 0) ? '&' : '?') + '_=' + Date.now();
}

return view.extend({
	load: function() {
		return uci.load('mihomo').then(function() {
			var url = uci.get('mihomo', 'main', 'dashboard');

			if (!url)
				url = 'http://' + (window.location.hostname || '192.168.1.1') + ':9090/ui';

			return L.resolveDefault(fs.exec(HELPER, [ 'status' ]), null).then(function(res) {
				return {
					url: url,
					st: (res && res.code == 0) ? parseKV(res.stdout) : null,
					err: (res && res.code != 0) ? joinOutput(res) : ''
				};
			});
		});
	},

	render: function(data) {
		var self = this;
		var st = data.st || {};
		var prevJob = st.JOB || 'idle';
		var pageURL = data.url;

		// ---------------- 结果提示 ----------------

		this.banner = E('div', { 'style': 'display:none; margin:1em 0; padding:.6em .8em; border-left:4px solid #999; border-radius:3px' }, [
			E('strong', { 'class': 'banner-title' }, [ '' ]),
			E('div', { 'class': 'banner-detail', 'style': 'margin-top:.4em; white-space:pre-wrap; font-family:monospace; font-size:90%' }, [ '' ])
		]);

		var setResult = function(kind, title, detail) {
			var k = KIND[kind] || KIND.info;
			var t = self.banner.querySelector('.banner-title');
			var d = self.banner.querySelector('.banner-detail');

			self.banner.style.display = '';
			self.banner.style.background = k[0];
			self.banner.style.borderLeftColor = k[1];
			self.banner.style.color = k[2];

			t.textContent = k[3] + ' ' + title;
			d.textContent = detail || '';
			d.style.display = detail ? '' : 'none';
		};

		// ---------------- 状态表 ----------------

		var cellState = E('span', [ '' ]);
		var cellDir = E('span', { 'style': 'font-family:monospace' }, [ '' ]);
		var cellFiles = E('span', [ '' ]);
		var cellTime = E('span', [ '' ]);
		var cellConfig = E('span', { 'style': 'font-family:monospace; font-size:90%' }, [ '' ]);

		var row = function(label, node) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'width:28%; white-space:nowrap' }, [ label ]),
				E('td', { 'class': 'td' }, [ node ])
			]);
		};

		var statusTable = E('table', { 'class': 'table' }, [
			E('tbody', [
				row(_('面板状态'), cellState),
				row(_('安装目录'), cellDir),
				row(_('文件 / 占用'), cellFiles),
				row(_('安装时间'), cellTime),
				row(_('关联配置'), cellConfig)
			])
		]);

		// ---------------- 操作区 ----------------

		var urlInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'style': 'width:100%; font-family:monospace',
			'placeholder': st.DEFAULT_URL || '',
			'value': loadSavedURL(st.DEFAULT_URL || '')
		});

		var installBtn = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, [ '' ]);
		var removeBtn = E('button', { 'class': 'btn cbi-button cbi-button-remove' }, [ _('删除面板') ]);
		var openBtn = E('button', { 'class': 'btn cbi-button' }, [ _('在新窗口打开') ]);
		var reloadBtn = E('button', { 'class': 'btn cbi-button' }, [ _('重新加载') ]);

		// ---------------- 任务进度 ----------------

		var jobLog = E('pre', {
			'style': 'max-height:220px; overflow:auto; margin:.5em 0 0; padding:.5em; ' +
				'background:#f7f7f7; border:1px solid #ddd; border-radius:3px; ' +
				'font-size:85%; white-space:pre-wrap'
		}, [ '' ]);

		var jobBox = E('div', { 'style': 'display:none; margin:1em 0' }, [
			E('div', { 'style': 'font-weight:bold' }, [ _('安装进度') ]),
			jobLog
		]);

		// ---------------- iframe ----------------

		var iframe = E('iframe', {
			'src': pageURL,
			'style': 'width:100%; height:calc(100vh - 230px); min-height:480px; ' +
				'border:1px solid #ccc; border-radius:3px; background:#fff'
		});

		var reloadIframe = function() {
			iframe.src = bust(pageURL);
		};

		openBtn.addEventListener('click', function() {
			window.open(pageURL, '_blank');
		});

		reloadBtn.addEventListener('click', function() {
			reloadIframe();
			setResult('info', _('已重新加载内嵌页面'), '');
		});

		// ---------------- 状态应用 ----------------

		var applyState = function(s) {
			var installed = (s.UI_STATE === 'installed');

			cellState.textContent = installed
				? _('已安装')
				: _('未安装 (面板文件不存在, /ui 会返回 404)');
			cellState.style.color = installed ? '#1b5e20' : '#b71c1c';

			cellDir.textContent = s.UI_DIR || '';

			if (installed) {
				cellFiles.textContent = _('%s 个文件, %s').format(
					s.UI_FILES || '0', fmtSize(s.UI_SIZE));
				cellTime.textContent = fmtUTC8(s.UI_MTIME) || '?';
			}
			else {
				cellFiles.textContent = '-';
				cellTime.textContent = '-';
			}

			var parts = [];

			if (s.EXTERNAL_UI)
				parts.push('external-ui: ' + s.EXTERNAL_UI);
			else
				parts.push(_('配置里没有 external-ui (mihomo 不会注册 /ui)'));
			if (s.EXTERNAL_CONTROLLER)
				parts.push('external-controller: ' + s.EXTERNAL_CONTROLLER);
			else
				parts.push(_('配置里没有 external-controller'));

			cellConfig.textContent = parts.join('   |   ');
			cellConfig.style.color = (s.EXTERNAL_UI && s.EXTERNAL_CONTROLLER) ? '' : '#e65100';

			installBtn.textContent = installed ? _('下载并安装 / 更新面板') : _('下载并安装面板');

			if (s.UI_INVALID)
				setResult('err', _('面板目录不可用'), s.UI_INVALID);

			// 任务状态: running 时把日志尾巴刷出来, 结束时给结论。
			if (s.JOB === 'running') {
				jobBox.style.display = '';
				installBtn.disabled = true;
				jobLog.textContent = _('正在下载…');

				return L.resolveDefault(fs.read(JOB_LOG), '').then(function(txt) {
					jobLog.textContent = tailText(txt, 14) || _('(还没有输出)');
				});
			}

			jobBox.style.display = 'none';
			installBtn.disabled = false;

			if (s.JOB === 'done' && prevJob !== 'done') {
				reloadIframe();
				setResult('ok', _('面板已安装'),
					_('文件已写入 %s, 无需重启 mihomo。若内嵌页面还是空白, 点「重新加载」。')
						.format(s.UI_DIR || ''));
			}
			else if (s.JOB === 'failed' && prevJob !== 'failed') {
				return L.resolveDefault(fs.read(JOB_LOG), '').then(function(txt) {
					setResult('err', _('安装失败 (退出码 %s)').format(s.JOB_RC || '?'),
						tailText(txt, 14) || _('(没有更多输出)'));
				});
			}

			prevJob = s.JOB || 'idle';

			return Promise.resolve();
		};

		var refresh = function() {
			return L.resolveDefault(fs.exec(HELPER, [ 'status' ]), null).then(function(res) {
				if (!res || res.code != 0) {
					setResult('err', _('读取面板状态失败'),
						joinOutput(res) || _('无法执行 %s').format(HELPER));
					return;
				}

				return applyState(parseKV(res.stdout));
			});
		};

		// ---------------- 动作 ----------------

		var doInstall = function() {
			var url = String(urlInput.value || '').trim();

			if (url && !/^https?:\/\//i.test(url)) {
				setResult('warn', _('URL 格式不正确'), _('只支持 http:// 或 https:// 开头的地址。'));
				return;
			}

			saveURL(url);

			installBtn.disabled = true;
			jobBox.style.display = '';
			jobLog.textContent = _('正在启动后台任务…');
			setResult('info', _('已开始下载'), _('下载与解压在后台进行, 本页会自动刷新进度。'));

			return fs.exec(HELPER, [ 'start', url ]).then(function(res) {
				var out = joinOutput(res);
				var kind = (String(out).match(/^RESULT:[ \t]*(\S+)/m) || [])[1] || '';

				if (kind === 'busy') {
					installBtn.disabled = false;
					jobBox.style.display = 'none';
					setResult('warn', _('已有安装任务在运行'), out);
					return;
				}

				if (res && res.code != 0) {
					installBtn.disabled = false;
					jobBox.style.display = 'none';
					setResult('err', _('无法启动安装任务'), out || _('(无输出)'));
					return;
				}

				prevJob = 'idle';
				window.setTimeout(refresh, 800);
			}, function(e) {
				installBtn.disabled = false;
				jobBox.style.display = 'none';
				setResult('err', _('无法执行'), String(e.message || e));
			});
		};

		var doRemove = function() {
			if (!window.confirm(_('确定删除面板目录 %s ?\n\n删除后 /ui 会返回 404, 直到重新安装。')
					.format(st.UI_DIR || '')))
				return Promise.resolve();

			removeBtn.disabled = true;
			setResult('info', _('正在删除…'), '');

			return fs.exec(HELPER, [ 'remove' ]).then(function(res) {
				var ok = (res && res.code == 0);
				removeBtn.disabled = false;

				setResult(ok ? 'ok' : 'err',
					ok ? _('面板已删除') : _('删除失败 (退出码 %s)').format(res ? res.code : '?'),
					joinOutput(res) || _('(无输出)'));

				return refresh();
			}, function(e) {
				removeBtn.disabled = false;
				setResult('err', _('无法执行'), String(e.message || e));
			});
		};

		installBtn.addEventListener('click', doInstall);
		removeBtn.addEventListener('click', doRemove);

		// 首次渲染就把状态画上, 之后每 3 秒跟一次 (只读几个文件, 很轻)。
		applyState(st);
		poll.add(refresh, 3);

		// ---------------- 视图 ----------------

		var descr = [
			_('内嵌 mihomo 外部控制器的 Web 管理界面 (metacubexd / yacd 等), 可视化管理代理节点、规则与连接。'),
			E('br'),
			_('当前地址: %s (可在「运行参数」页修改, 留空则默认 http://<路由器地址>:9090/ui)。').format(pageURL),
			E('br'),
			_('面板文件不在软件包里, 首次使用需要点下面的按钮下载。下载源可换成镜像地址; 留空则使用 metacubexd 官方构建。')
		];

		if (!data.st) {
			descr = [
				E('span', { 'style': 'color:#b71c1c; font-weight:bold' }, [
					_('找不到 %s, 无法管理面板文件。').format(HELPER)
				]),
				E('br'),
				_('该脚本由 luci-app-mihomo 1.0.4 起提供, 请确认包已升级到最新版本。'),
				E('br'),
				E('span', { 'style': 'font-family:monospace; font-size:90%' }, [ data.err || '' ])
			];
		}

		return E([
			E('h2', [ _('Mihomo 后台管理') ]),
			E('div', { 'class': 'cbi-map-descr' }, descr),
			this.banner,
			E('div', { 'class': 'cbi-section', 'style': 'margin-top:1em' }, [ statusTable ]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('下载地址') ]),
					E('div', { 'class': 'cbi-value-field' }, [
						urlInput,
						E('div', { 'class': 'cbi-value-description' }, [
							_('默认为 metacubexd 的 gh-pages 构建。若路由器访问 GitHub 困难, 可换成镜像或自建的 zip 地址。')
						])
					])
				]),
				E('div', { 'style': 'margin:1em 0' }, [
					installBtn, ' ', removeBtn, ' ', openBtn, ' ', reloadBtn
				]),
				jobBox
			]),
			iframe
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
