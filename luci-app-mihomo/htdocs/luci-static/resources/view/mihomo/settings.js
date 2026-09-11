'use strict';
'require view';
'require form';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('mihomo', _('Mihomo 运行参数'),
			_('修改后点击「保存并应用」。修改参数不会自动重启已在运行的服务, 请到「运行状态」页点击「重启」使其生效。开启/关闭「开机自启」只影响服务的启动门槛与随开机拉起, 不会立即启动或停止服务。'));

		s = m.section(form.NamedSection, 'main', 'mihomo', _('基本设置'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('开机自启'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.option(form.Value, 'conffile', _('配置文件路径'),
			_('Mihomo 主配置文件 (YAML) 的绝对路径。安装包自带的示例文件为 /etc/mihomo/example.yaml, 需自行准备 config.yaml 后才能启动。'));
		o.placeholder = '/etc/mihomo/config.yaml';
		o.rmempty = false;

		o = s.option(form.Value, 'workdir', _('工作目录'),
			_('Mihomo 运行数据目录 (缓存、GeoIP 数据等), 需为绝对路径。'));
		o.placeholder = '/etc/mihomo';
		o.rmempty = false;

		o = s.option(form.Value, 'user', _('运行用户'),
			_('运行 Mihomo 的系统用户。使用透明代理（REDIRECT/TPROXY）时请保持 root。'));
		o.placeholder = 'root';
		o.rmempty = false;

		o = s.option(form.DynamicList, 'ifaces', _('监听接口'),
			_('网络状态变化时触发服务自动重启的接口, 例如 wan、wan_6。'));
		o.placeholder = 'wan';

		o = s.option(form.Flag, 'log_stdout', _('标准输出写入系统日志'));
		o.default = o.enabled;

		o = s.option(form.Flag, 'log_stderr', _('错误输出写入系统日志'));
		o.default = o.enabled;

		o = s.option(form.Value, 'dashboard', _('后台管理地址'),
			_('mihomo 外部控制器 Web 界面地址 (metacubexd / yacd 等), 留空则默认 http://<路由器地址>:9090/ui。需在 mihomo 配置文件中启用 external-controller 与 external-ui。'));
		o.placeholder = 'http://192.168.1.1:9090/ui';

		return m.render();
	}
});
