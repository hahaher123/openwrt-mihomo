'use strict';
'require view';
'require fs';
'require uci';
'require ui';

var SCRIPT_PATH = '/etc/mihomo/tproxy.sh';
var NFT_PATH = '/etc/mihomo/clash.nft';

return view.extend({
	handleToggleTransparent: function(ev) {
		var next = (uci.get('mihomo', 'main', 'transparent') == '1') ? '0' : '1';

		uci.set('mihomo', 'main', 'transparent', next);

		return uci.save().then(function() {
			return uci.apply();
		}).then(function() {
			ui.addNotification(null, E('p', next == '1'
				? _('透明代理已开启, mihomo 重启后将自动加载路由与 nft 规则')
				: _('透明代理已关闭, 规则将在服务停止/重启时移除')), 'info');
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('修改透明代理开关失败: %s').format(String(e.message || e))), 'error');
		});
	},

	handleSaveFile: function(path, textarea, ev) {
		return fs.write(path, textarea.value).then(function() {
			ui.addNotification(null, E('p', _('%s 已保存, 重启 mihomo 服务后生效').format(path)), 'info');
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('保存 %s 失败: %s').format(path, String(e.message || e))), 'error');
		});
	},

	handleCheck: function(outputPre, ev) {
		outputPre.textContent = _('检查中…');

		return fs.exec('/etc/init.d/mihomo', [ 'tproxystatus' ]).then(function(res) {
			var out = (res && res.stdout) ? res.stdout : '';
			if (res && res.stderr)
				out += (out ? '\n' : '') + '[stderr]\n' + res.stderr;

			outputPre.textContent = out || _('(无输出)');
		}).catch(function(e) {
			// rc.common prints its usage text on the stdout stream, so show
			// both streams when the command fails instead of a bare message.
			var msg = (e && (e.stdout || e.stderr)) || String(e.message || e);

			if (e && e.stdout && e.stderr)
				msg = e.stdout + '\n[stderr]\n' + e.stderr;

			outputPre.textContent = _('检查失败: %s').format(msg);
		});
	},

	load: function() {
		return Promise.all([
			L.resolveDefault(fs.read(SCRIPT_PATH), ''),
			L.resolveDefault(fs.read(NFT_PATH), ''),
			uci.load('mihomo')
		]);
	},

	render: function(data) {
		var self = this;
		var transparent = (uci.get('mihomo', 'main', 'transparent') == '1');

		var transparentBtn = E('button', {
			'class': 'btn cbi-button ' + (transparent ? 'cbi-button-negative' : 'cbi-button-positive'),
			'style': 'font-size:1.1em; padding:8px 22px;',
			'click': ui.createHandlerFn(self, 'handleToggleTransparent')
		}, [ transparent ? _('关闭透明代理') : _('开启透明代理') ]);

		var transparentInfo = E('span', {
			'style': 'margin-left:12px; font-weight:600; color:' + (transparent ? '#2e9e44' : '#b06000')
		}, [ transparent ? _('已开启') : _('未开启') ]);

		var editor = function(rows) {
			return E('textarea', {
				'rows': rows,
				'style': 'width:100%; font-family:monospace; white-space:pre; padding:8px; border:1px solid #e2e2e2; border-radius:6px; background:#f6f6f6;'
			}, []);
		};

		var scriptTa = editor(14);
		scriptTa.value = data[0] || '';

		var nftTa = editor(28);
		nftTa.value = data[1] || '';

		var saveBtn = function(path, ta) {
			return E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(self, 'handleSaveFile', path, ta)
			}, [ _('保存文件') ]);
		};

		var outputPre = E('pre', {
			'style': 'max-height:360px; overflow:auto; padding:10px; white-space:pre-wrap; word-break:break-all; background:#f6f6f6; border:1px solid #e2e2e2; border-radius:8px; font-size:0.9em;'
		}, [ _('点击「检查规则状态」查看当前 ip rule 与 nft 规则') ]);

		return E([
			E('h2', [ _('透明代理 (TPROXY)') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('开启后, mihomo 启动前自动添加 fwmark 策略路由 (执行 %s) 并加载 nft 规则 (%s), 服务停止时自动移除。').format(SCRIPT_PATH, NFT_PATH),
				E('br'),
				_('要求 mihomo 配置文件中设置 tproxy-port: 7894 (与 nft 规则中的端口一致)。'),
				E('br'),
				E('b', {}, [ _('注意: 请勿再保留旧版 fw4 include 文件 /etc/nftables.d/11-clash.nft, 否则规则会重复加载。') ])
			]),

			E('div', { 'style': 'margin:14px 0' }, [ transparentBtn, transparentInfo ]),

			E('h3', {}, [ _('策略路由脚本 (%s)').format(SCRIPT_PATH) ]),
			scriptTa,
			E('div', { 'style': 'margin:8px 0 16px 0' }, [ saveBtn(SCRIPT_PATH, scriptTa) ]),

			E('h3', {}, [ _('nft 规则文件 (%s)').format(NFT_PATH) ]),
			nftTa,
			E('div', { 'style': 'margin:8px 0 16px 0' }, [ saveBtn(NFT_PATH, nftTa) ]),

			E('h3', {}, [ _('规则状态检查') ]),
			E('div', { 'style': 'margin-bottom:8px' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(self, 'handleCheck', outputPre)
				}, [ _('检查规则状态') ])
			]),
			outputPre
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
