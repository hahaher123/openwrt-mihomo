'use strict';
'require view';
'require fs';
'require uci';
'require ui';

//
// 配置文件管理页
//
// - 列出 workdir 下的 *.yaml/*.yml, 可选中其中一个作为当前运行配置
//   (写入 uci mihomo.main.conffile, 与 /etc/init.d/mihomo 读的是同一项)
// - 从远程 URL 导入 clash/mihomo 订阅, 先校验再落盘
//   (由 /etc/mihomo/config.sh import 完成, 下载到 /tmp 校验通过后才安装)
// - 直接编辑选中的配置文件: 校验 / 保存 / 保存并重启
//   保存与保存并重启都会先校验, 校验不通过不写文件
//
// 校验统一用上游自带的 "mihomo -t", 参数与服务启动一致 (-f <配置> -d <workdir>)。
// mihomo 按 -d 解析配置内的相对路径 (constant/path.go: Resolve 用 HomeDir),
// 所以把待校验内容放 /tmp 校验与放 workdir 校验结果等价, 且不必为校验写 flash。
//

var MIHOMO_BIN = '/usr/bin/mihomo';
var HELPER = '/etc/mihomo/config.sh';
var CHECK_FILE = '/tmp/mihomo-config-check.yaml';

var DEFAULT_WORKDIR = '/etc/mihomo';
var DEFAULT_CONFFILE = '/etc/mihomo/config.yaml';

// rpcd 的 file ACL 按路径授权 (支持 * 通配), 这里覆盖的是默认目录。
var ACL_WORKDIR = '/etc/mihomo';

// kind -> [背景, 左边框, 文字, 前缀]
var KIND = {
	ok:   [ '#e8f5e9', '#2e7d32', '#1b5e20', '✔' ],
	err:  [ '#fdecea', '#c62828', '#b71c1c', '✘' ],
	warn: [ '#fff8e1', '#ef6c00', '#e65100', '▲' ],
	info: [ '#e8f0fe', '#1565c0', '#0d47a1', '➜' ]
};

function fmtSize(n) {
	if (n == null || isNaN(n))
		return '';
	if (n < 1024)
		return '%d B'.format(n);
	if (n < 1024 * 1024)
		return '%.1f KB'.format(n / 1024);
	return '%.1f MB'.format(n / (1024 * 1024));
}

// 合并 mihomo -t 的 stdout/stderr。mihomo 的日志走 stdout
// (log/log.go: log.SetOutput(os.Stdout)), 失败诊断因此在 stdout。
function joinOutput(res) {
	var out = (res && res.stdout) ? String(res.stdout) : '';
	var err = (res && res.stderr) ? String(res.stderr) : '';

	out = out.replace(/\s+$/, '');
	err = err.replace(/\s+$/, '');

	if (out && err)
		return out + '\n[stderr]\n' + err;

	return out || err;
}

function isConfigName(name) {
	return /\.(ya?ml)$/i.test(name || '');
}

return view.extend({
	// ---------------- 结果提示 ----------------

	setResult: function(kind, title, detail, silent) {
		var k = KIND[kind] || KIND.info;

		if (this.banner) {
			this.banner.style.display = '';
			this.banner.style.background = k[0];
			this.banner.style.borderLeftColor = k[1];
			this.banner.style.color = k[2];
			this.bannerTitle.textContent = k[3] + '  ' + title;
			this.bannerPre.textContent = detail ? String(detail) : '';
			this.bannerPre.style.display = detail ? '' : 'none';

			if (this.banner.scrollIntoView)
				this.banner.scrollIntoView({ block: 'nearest' });
		}

		if (!silent) {
			var type = (kind == 'err') ? 'error' : (kind == 'warn' ? 'warning' : 'info');
			ui.addNotification(null, E('p', {}, [ title ]), type);
		}
	},

	// ---------------- 基础信息 ----------------

	cfg: function() {
		return {
			workdir: uci.get('mihomo', 'main', 'workdir') || DEFAULT_WORKDIR,
			conffile: uci.get('mihomo', 'main', 'conffile') || DEFAULT_CONFFILE,
			enabled: uci.get('mihomo', 'main', 'enabled') == '1'
		};
	},

	basename: function(path) {
		return String(path || '').substring(String(path || '').lastIndexOf('/') + 1);
	},

	pathOf: function(name) {
		return this.cfg().workdir + '/' + name;
	},

	restartNote: function() {
		if (this.cfg().enabled)
			return '';

		return _('\n注意: uci mihomo.main.enabled = 0, 服务处于禁用状态, 重启不会真正拉起进程。请先在「运行状态」页开启。');
	},

	// ---------------- 校验 / 重启 ----------------

	// 用 mihomo -t 校验一段配置内容, 返回 { code, stdout, stderr }。
	// 注意 fs.exec 在命令退出码非 0 时不会 reject, 必须自己看 code。
	validateContent: function(content, workdir) {
		return fs.write(CHECK_FILE, content).then(function() {
			return fs.exec(MIHOMO_BIN, [ '-t', '-f', CHECK_FILE, '-d', workdir ]);
		});
	},

	failText: function(code) {
		return _('校验失败 (mihomo -t 退出码 %s)').format(code);
	},

	restartService: function() {
		return fs.exec('/etc/init.d/mihomo', [ 'restart' ]);
	},

	// ---------------- 列表 ----------------

	sortedNames: function(entries) {
		var names = [];

		for (var i = 0; i < (entries || []).length; i++) {
			var e = entries[i];
			if (e && e.type == 'file' && isConfigName(e.name))
				names.push({ name: e.name, size: e.size });
		}

		names.sort(function(a, b) {
			return (a.name < b.name) ? -1 : (a.name > b.name ? 1 : 0);
		});

		return names;
	},

	// 初始选中项: 优先当前生效的配置, 否则第一个文件。
	pickInitial: function(entries) {
		var names = this.sortedNames(entries);
		var cur = this.basename(this.cfg().conffile);

		for (var i = 0; i < names.length; i++)
			if (names[i].name == cur)
				return cur;

		return names.length ? names[0].name : null;
	},

	buildList: function(entries, listError) {
		var self = this;
		var c = this.cfg();

		while (this.listBox.firstChild)
			this.listBox.removeChild(this.listBox.firstChild);

		if (listError) {
			this.listBox.appendChild(E('div', {
				'style': 'padding:10px; color:#b71c1c; background:#fdecea; border:1px solid #c62828; border-radius:6px;'
			}, [ _('读取目录 %s 失败: %s').format(c.workdir, listError) ]));
			return;
		}

		var names = this.sortedNames(entries);

		if (names.length == 0) {
			this.listBox.appendChild(E('div', {
				'style': 'padding:10px; color:#e65100; background:#fff8e1; border:1px solid #ef6c00; border-radius:6px;'
			}, [ _('目录 %s 下没有 .yaml 配置文件, 可先在上方从远程导入。').format(c.workdir) ]));
			return;
		}

		for (var i = 0; i < names.length; i++) {
			var name = names[i].name;
			var isCur = (name == this.basename(c.conffile));
			var isSel = (name == this.selected);

			var row = [
				E('input', {
					'type': 'radio',
					'name': 'cfgfile',
					'value': name,
					'checked': isSel ? '' : null,
					'change': ui.createHandlerFn(self, 'handlePick', name)
				}),
				E('span', { 'style': 'font-family:monospace; font-weight:600;' }, [ name ]),
				E('span', { 'style': 'color:#888; font-size:0.9em;' }, [ fmtSize(names[i].size) ])
			];

			if (isCur) {
				row.push(E('span', {
					'style': 'margin-left:auto; padding:2px 8px; border-radius:10px; background:#e8f5e9; color:#1b5e20; border:1px solid #2e7d32; font-size:0.85em; font-weight:600;'
				}, [ _('当前生效') ]));
			}
			else {
				row.push(E('span', { 'style': 'margin-left:auto;' }, [ '' ]));
			}

			this.listBox.appendChild(E('label', {
				'style': 'display:flex; align-items:center; gap:8px; padding:7px 10px; margin-bottom:6px; border:1px solid ' +
					(isSel ? '#1565c0' : (isCur ? '#2e7d32' : '#e2e2e2')) + '; border-radius:6px; background:#fff; cursor:pointer;'
			}, row));
		}
	},

	refreshList: function() {
		var self = this;
		var c = this.cfg();

		return fs.list(c.workdir).then(function(entries) {
			var names = self.sortedNames(entries);
			var stillThere = false;

			for (var i = 0; i < names.length; i++)
				if (names[i].name == self.selected)
					stillThere = true;

			if (!stillThere)
				self.selected = self.pickInitial(entries);

			self.buildList(entries, null);
		}, function(e) {
			self.buildList([], String(e.message || e));
		});
	},

	// ---------------- 动作: 选择文件 ----------------

	handlePick: function(name, ev) {
		var self = this;

		this.selected = name;
		this.editPath.textContent = this.pathOf(name);

		return fs.read(this.pathOf(name)).then(function(content) {
			self.ta.value = content || '';
		}, function(e) {
			self.ta.value = '';
			self.setResult('err', _('读取 %s 失败').format(self.pathOf(name)), String(e.message || e));
		});
	},

	// ---------------- 动作: 远程导入 ----------------

	handleImport: function(ev) {
		var self = this;
		var url = String(this.urlInput.value || '').trim();
		var name = String(this.nameInput.value || '').trim();
		var args = [ 'import', url ];

		if (!url) {
			this.setResult('warn', _('请先填写订阅 URL'), '');
			return;
		}

		if (name)
			args.push(name);
		if (this.forceBox.checked)
			args.push('force');

		this.setResult('info', _('正在导入…'), url, true);

		return fs.exec(HELPER, args).then(function(res) {
			var ok = (res && res.code == 0);
			var out = joinOutput(res);

			self.setResult(ok ? 'ok' : 'err',
				ok ? _('导入成功') : _('导入失败 (退出码 %s)').format(res ? res.code : '?'),
				out || _('(无输出)'));

			if (!ok)
				return;

			// 刷新列表; 若当前编辑的就是目标文件, 内容也一并刷新
			return self.refreshList().then(function() {
				if (self.selected)
					return self.handlePick(self.selected);
			});
		}, function(e) {
			// 权限不足等 RPC 级失败走这里, 此时没有 code 可看
			self.setResult('err', _('导入无法执行'), String(e.message || e));
		});
	},

	// ---------------- 动作: 选择运行配置 ----------------

	doApplyConfig: function(restart) {
		var self = this;
		var name = this.selected;
		var path = name ? this.pathOf(name) : null;

		if (!name) {
			this.setResult('warn', _('请先在上面的列表中选择一个配置文件'), '');
			return Promise.resolve();
		}

		uci.set('mihomo', 'main', 'conffile', path);

		return uci.save().then(function() {
			return uci.apply();
		}).then(function() {
			if (!restart) {
				self.setResult('ok', _('已设为当前配置'), path + '\n' + _('重启 mihomo 服务后生效。'));
				return self.refreshList();
			}

			self.setResult('info', _('已切换配置, 正在重启服务…'), path, true);

			return self.restartService().then(function(res) {
				var ok = (res && res.code == 0);
				var out = joinOutput(res);

				self.setResult(ok ? 'ok' : 'err',
					ok ? _('已切换配置并重启服务') : _('服务重启失败 (退出码 %s)').format(res ? res.code : '?'),
					path + '\n\n' + (out || _('(无输出)')) + self.restartNote());

				return self.refreshList();
			});
		}, function(e) {
			self.setResult('err', _('切换配置失败'), String(e.message || e));
		});
	},

	handleSetConfig: function(ev) {
		return this.doApplyConfig(false);
	},

	handleSetConfigRestart: function(ev) {
		return this.doApplyConfig(true);
	},

	// ---------------- 动作: 校验 / 保存 ----------------

	handleValidate: function(ev) {
		var self = this;

		if (!this.selected) {
			this.setResult('warn', _('请先在上面的列表中选择一个配置文件'), '');
			return;
		}

		var c = this.cfg();

		this.setResult('info', _('正在校验…'), '', true);

		return this.validateContent(this.ta.value, c.workdir).then(function(res) {
			var ok = (res && res.code == 0);

			self.setResult(ok ? 'ok' : 'err',
				ok ? _('校验通过, 配置可被 mihomo 正常加载') : self.failText(res ? res.code : '?'),
				joinOutput(res) || _('(无输出)'));
		}, function(e) {
			self.setResult('err', _('校验无法执行'), String(e.message || e));
		});
	},

	// 保存与保存并重启共用: 先校验, 通过才写盘; restart 为真时再重启服务。
	doSave: function(restart) {
		var self = this;
		var name = this.selected;

		if (!name) {
			this.setResult('warn', _('请先在上面的列表中选择一个配置文件'), '');
			return Promise.resolve();
		}

		var c = this.cfg();
		var path = this.pathOf(name);
		var content = this.ta.value;

		this.setResult('info', _('正在校验…'), '', true);

		return this.validateContent(content, c.workdir).then(function(res) {
			if (!res || res.code != 0) {
				self.setResult('err', _('校验失败, 未保存'),
					(res && res.code != null ? self.failText(res.code) + '\n\n' : '') +
					(joinOutput(res) || _('(无输出)')));
				return;
			}

			// 0644 会被 rpcd 用在新建文件上, 这里显式请求 0600 (与 INSTALL_CONF 一致),
			// 配置文件含订阅凭据, 不宜全局可读。
			return fs.write(path, content, 384).then(function() {
				if (!restart) {
					self.setResult('ok', _('保存成功'),
						path + '\n' + _('校验已通过, 重启 mihomo 服务后生效。'));
					return;
				}

				self.setResult('info', _('已保存, 正在重启服务…'), path, true);

				return self.restartService().then(function(r) {
					var ok = (r && r.code == 0);
					var out = joinOutput(r);

					self.setResult(ok ? 'ok' : 'err',
						ok ? _('保存并重启成功') : _('保存成功, 但服务重启失败 (退出码 %s)').format(r ? r.code : '?'),
						path + '\n\n' + (out || _('(无输出)')) + self.restartNote());

					return self.refreshList();
				});
			}, function(e) {
				self.setResult('err', _('保存失败'), String(e.message || e));
			});
		}, function(e) {
			self.setResult('err', _('校验无法执行'), String(e.message || e));
		});
	},

	handleSaveCfg: function(ev) {
		return this.doSave(false);
	},

	handleSaveCfgRestart: function(ev) {
		return this.doSave(true);
	},

	// ---------------- 生命周期 ----------------

	load: function() {
		var self = this;

		return uci.load('mihomo').then(function() {
			var c = self.cfg();

			return fs.list(c.workdir).then(function(entries) {
				return { entries: entries, error: null };
			}, function(e) {
				return { entries: [], error: String(e.message || e) };
			});
		}).then(function(listing) {
			self.selected = self.pickInitial(listing.entries);

			if (!self.selected) {
				listing.content = '';
				return listing;
			}

			return L.resolveDefault(fs.read(self.pathOf(self.selected)), '').then(function(content) {
				listing.content = content;
				return listing;
			});
		});
	},

	render: function(data) {
		var self = this;
		var c = this.cfg();

		if (!this.selected)
			this.selected = this.pickInitial(data.entries);

		// ---- 结果横幅 ----
		this.bannerTitle = E('div', {
			'style': 'font-size:1.05em; font-weight:700;'
		}, [ _('尚未执行任何操作') ]);

		this.bannerPre = E('pre', {
			'style': 'display:none; margin:8px 0 0 0; max-height:300px; overflow:auto; padding:10px; white-space:pre-wrap; word-break:break-all; background:rgba(255,255,255,0.7); border-radius:6px; font-size:0.9em; color:#333;'
		}, [ '' ]);

		this.banner = E('div', {
			'style': 'position:sticky; top:0; z-index:10; margin:12px 0 18px 0; padding:12px 14px; border-left:6px solid #9e9e9e; border-radius:8px; background:#f5f5f5; color:#333; box-shadow:0 1px 4px rgba(0,0,0,0.12);'
		}, [ this.bannerTitle, this.bannerPre ]);

		// ---- 列表 ----
		this.listBox = E('div', {}, []);

		// ---- 编辑区 ----
		this.ta = E('textarea', {
			'rows': 28,
			'spellcheck': 'false',
			'style': 'width:100%; font-family:monospace; white-space:pre; padding:8px; border:1px solid #e2e2e2; border-radius:6px; background:#f6f6f6;'
		}, []);
		this.ta.value = data.content || '';

		this.editPath = E('code', {}, [ this.selected ? this.pathOf(this.selected) : c.conffile ]);

		// ---- 导入表单 ----
		this.urlInput = E('input', {
			'type': 'text',
			'placeholder': 'https://example.com/sub?token=...',
			'style': 'width:100%; padding:7px 8px; border:1px solid #e2e2e2; border-radius:6px; font-family:monospace;'
		}, []);

		this.nameInput = E('input', {
			'type': 'text',
			'placeholder': _('留空则按 URL 自动命名'),
			'style': 'width:100%; padding:7px 8px; border:1px solid #e2e2e2; border-radius:6px; font-family:monospace;'
		}, []);

		this.forceBox = E('input', { 'type': 'checkbox' }, []);

		var btn = function(label, handler, cls) {
			return E('button', {
				'class': 'btn cbi-button ' + (cls || 'cbi-button-apply'),
				'style': 'padding:7px 18px;',
				'click': ui.createHandlerFn(self, handler)
			}, [ label ]);
		};

		var root = E([
			E('h2', {}, [ _('配置文件') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('管理 %s 下的 clash/mihomo 配置文件: 远程导入订阅、选择运行哪一个、直接编辑内容。').format(c.workdir),
				E('br'),
				_('当前生效配置由 uci mihomo.main.conffile 指定 (与 /etc/init.d/mihomo 同源), 现为 %s。').format(c.conffile),
				E('br'),
				_('校验使用上游自带的 mihomo -t, 参数与服务启动一致; 保存与保存并重启都会先校验, 校验不通过不会写入文件。')
			]),

			(c.workdir == ACL_WORKDIR) ? '' : E('div', {
				'style': 'margin:10px 0; padding:9px 12px; border-left:4px solid #ef6c00; background:#fff8e1; color:#e65100; border-radius:6px;'
			}, [ _('注意: workdir 已被改为 %s, 而本页面的 rpcd 授权只覆盖 %s, 读写该目录会提示权限不足。').format(c.workdir, ACL_WORKDIR) ]),

			this.banner,

			E('h3', {}, [ _('远程导入') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('下载远程订阅并写入 %s。流程: 下载到 /tmp → mihomo -t 校验 → 通过后才安装; 校验失败的配置不会落盘, 也不会覆盖已有文件。').format(c.workdir)
			]),
			E('div', { 'style': 'display:grid; grid-template-columns:1fr 260px; gap:8px; margin:10px 0 6px 0;' }, [
				this.urlInput,
				this.nameInput
			]),
			E('div', { 'style': 'display:flex; align-items:center; gap:18px; flex-wrap:wrap;' }, [
				E('label', { 'style': 'display:flex; align-items:center; gap:6px; color:#555;' }, [
					this.forceBox, _('覆盖同名文件')
				]),
				btn(_('导入'), 'handleImport')
			]),

			E('h3', {}, [ _('选择用于运行的配置') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('选中一项后可设为当前生效配置; 「设为当前配置」只改 uci, 「设为当前配置并重启」会同时重启服务。')
			]),
			E('div', { 'style': 'margin:10px 0;' }, [ this.listBox ]),
			E('div', { 'style': 'display:flex; gap:10px; flex-wrap:wrap;' }, [
				btn(_('设为当前配置'), 'handleSetConfig', 'cbi-button'),
				btn(_('设为当前配置并重启'), 'handleSetConfigRestart')
			]),

			E('h3', {}, [ _('编辑选中的配置文件') ]),
			E('div', { 'class': 'cbi-map-descr' }, [ _('正在编辑: '), this.editPath ]),
			this.ta,
			E('div', { 'style': 'display:flex; gap:10px; margin:10px 0 24px 0; flex-wrap:wrap;' }, [
				btn(_('校验'), 'handleValidate', 'cbi-button'),
				btn(_('保存'), 'handleSaveCfg', 'cbi-button'),
				btn(_('保存并重启'), 'handleSaveCfgRestart')
			])
		]);

		this.buildList(data.entries, data.error);

		if (data.error)
			this.setResult('err', _('读取目录 %s 失败').format(c.workdir), data.error, true);

		return root;
	},

	// 抑制 LuCI 默认的页脚保存/应用条
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
