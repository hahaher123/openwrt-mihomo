'use strict';
'require view';
'require uci';

return view.extend({
	load: function() {
		return uci.load('mihomo').then(function() {
			var url = uci.get('mihomo', 'main', 'dashboard');

			if (!url)
				url = 'http://' + (window.location.hostname || '192.168.1.1') + ':9090/ui';

			return url;
		});
	},

	render: function(url) {
		var iframe = E('iframe', {
			'src': url,
			'style': 'width:100%; height:calc(100vh - 230px); min-height:480px; border:1px solid #ccc; border-radius:3px; background:#fff;'
		});

		var openBtn = E('button', {
			'class': 'btn cbi-button cbi-button-apply',
			'click': function() {
				window.open(url, '_blank');
			}
		}, [ _('在新窗口打开') ]);

		var reloadBtn = E('button', {
			'class': 'btn cbi-button',
			'click': function() {
				iframe.src = url;
			}
		}, [ _('重新加载') ]);

		return E([
			E('h2', [ _('Mihomo 后台管理') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('内嵌 mihomo 外部控制器的 Web 管理界面 (metacubexd / yacd 等), 可视化管理代理节点、规则与连接。'),
				E('br'),
				_('当前地址: %s (可在「运行参数」页修改, 留空则默认 http://<路由器地址>:9090/ui)。').format(url),
				E('br'),
				_('使用前需在 mihomo 配置文件中启用 external-controller (如 0.0.0.0:9090) 与 external-ui (如 ui), 并将仪表盘文件放入对应目录。若页面空白, 请用「在新窗口打开」直接访问。')
			]),
			E('div', { 'style': 'margin:1em 0' }, [ openBtn, ' ', reloadBtn ]),
			iframe
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
