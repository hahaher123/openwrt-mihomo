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
// - 仅更新服务器和代理组: 按订阅链接重新拉取, 只替换选中配置里的
//   proxies / proxy-groups 两段, 其余设置与手动修改都保持不动
//   (由 /etc/mihomo/config.sh update 完成)
// - 直接编辑选中的配置文件: 校验 / 保存 / 保存并重启
//   保存与保存并重启都会先校验, 校验不通过不写文件
// - 定时更新: 把「仅更新」写成一条 cron 计划任务 (由 /etc/mihomo/autoupdate.sh
//   的 set/apply 写 /etc/crontabs/root, 只动它自己那块带标记的内容), 设置存在
//   uci mihomo.autoupdate (enabled/target/schedule/url); 本页面只读 uci,
//   写入交给脚本 (避开 ubus 提交带来的服务 reload, 详见 autoupdate.sh)
//
// 订阅链接记录在 <workdir>/sources ("<name> <url>" 每行一条), 由 config.sh
// 在 import/update 时写入, 本页面只读取它来预填「仅更新」的链接输入框。
//
// 校验统一用上游自带的 "mihomo -t", 参数与服务启动一致 (-f <配置> -d <workdir>)。
// mihomo 按 -d 解析配置内的相对路径 (constant/path.go: Resolve 用 HomeDir),
// 所以把待校验内容放 /tmp 校验与放 workdir 校验结果等价, 且不必为校验写 flash。
//

var MIHOMO_BIN = '/usr/bin/mihomo';
var HELPER = '/etc/mihomo/config.sh';
var AUTOUPDATE = '/etc/mihomo/autoupdate.sh';
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

// 定时更新的执行时间选项: [cron 表达式, 说明]。最后一项是自定义。
var AUTO_DEFAULT_SCHEDULE = '0 4 * * *';

var AUTO_SCHEDULES = [
	[ '0 * * * *',    '每小时 (整点)' ],
	[ '0 */6 * * *',  '每 6 小时' ],
	[ '0 */12 * * *', '每 12 小时' ],
	[ '0 4 * * *',    '每天 04:00' ],
	[ '0 4 * * 1',    '每周一 04:00' ],
	[ 'custom',       '自定义 cron 表达式' ]
];

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

	// ---------------- 订阅链接记录 ----------------

	sourcePath: function() {
		return this.cfg().workdir + '/sources';
	},

	// 解析 <workdir>/sources: 每行 "<配置文件名> <URL>"
	parseSources: function(text) {
		var map = {};
		var lines = String(text || '').split('\n');

		for (var i = 0; i < lines.length; i++) {
			var m = lines[i].match(/^(\S+)[ \t]+(\S.*)$/);
			if (m)
				map[m[1]] = m[2].replace(/[ \t]+$/, '');
		}

		return map;
	},

	loadSources: function() {
		var self = this;

		return L.resolveDefault(fs.read(this.sourcePath()), '').then(function(text) {
			self.sources = self.parseSources(text);
			return self.sources;
		});
	},

	reloadSource: function() {
		var self = this;

		return this.loadSources().then(function() {
			self.syncSourceField();
		});
	},

	// 把选中项记录的订阅链接同步到「仅更新」的输入框。
	// replace 为真时无条件覆盖输入框 (切换选中项时必须覆盖, 否则会残留上一项的
	// 链接而造成更新到错误的目标)。
	syncSourceField: function(replace) {
		if (!this.updUrl)
			return;

		var name = this.selected;
		var url = name ? ((this.sources || {})[name] || '') : '';

		if (replace || !this.updUrl.value)
			this.updUrl.value = url;

		if (this.updInfo) {
			if (!name)
				this.updInfo.textContent = _('尚未选择配置文件。');
			else if (url)
				this.updInfo.textContent = _('选中 %1$s, 已记录的订阅链接: %2$s').format(name, url);
			else
				this.updInfo.textContent = _('选中 %1$s, 但没有记录订阅链接, 请在上方输入框里手动填写。').format(name);
		}
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

		// 定时更新的目标下拉框与这份清单同源, 一起刷新
		this.fillAutoTargets(entries);

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

		// 切换目标时必须覆盖链接输入框, 否则会把上一项的链接用到新目标上
		this.syncSourceField(true);

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

	// ---------------- 动作: 仅更新服务器和代理组 ----------------

	// 内容有没有变、要不要重启服务, 都由脚本判断后决定, 页面不再单独提供
	// 「并重启」按钮 —— 那样两个按钮的行为会完全一样。
	handleUpdateCfg: function(ev) {
		return this.doUpdate();
	},

	// 只刷新 proxies / proxy-groups 两段, 其余内容 (rules / dns / tun 等以及
	// 手动修改) 由脚本原样保留。下载、提取、对比、校验、写入与重启全在服务端
	// 完成; 脚本最后会打印一行 "RESULT: ..." 说明它究竟做了哪一步。
	doUpdate: function() {
		var self = this;
		var name = this.selected;

		if (!name) {
			this.setResult('warn', _('请先在上面的列表中选择一个配置文件'), '');
			return Promise.resolve();
		}

		var path = this.pathOf(name);
		var url = String(this.updUrl.value || '').trim();
		var recorded = (this.sources || {})[name] || '';

		if (!url && !recorded) {
			this.setResult('warn', _('缺少订阅链接'),
				_('配置 %s 没有记录订阅链接, 请在上方输入框里填写后重试。').format(name));
			return Promise.resolve();
		}

		var args = [ 'update', name ];
		if (url)
			args.push(url);

		// 更新只基于磁盘上的文件: 编辑区里未保存的修改不会被纳入, 更新成功后编辑区
		// 又会被刷新覆盖, 所以先拦下来让用户决定。
		return fs.read(path).then(function(disk) {
			if (String(disk == null ? '' : disk) !== String(self.ta.value || '')) {
				self.setResult('warn', _('请先保存或放弃编辑区的修改'),
					_('编辑区内容与磁盘上的 %s 不一致。').format(path) + '\n' +
					_('「仅更新」只基于磁盘上的文件内容, 未保存的修改不会被纳入, 更新成功后编辑区也会被刷新。'));
				return;
			}

			self.setResult('info', _('正在更新…'), _('目标: %s').format(path), true);

			return fs.exec(HELPER, args).then(function(res) {
				var ok = (res && res.code == 0);
				var out = joinOutput(res) || _('(无输出)');

				if (!ok) {
					self.setResult('err', _('更新失败 (退出码 %s)').format(res ? res.code : '?'), out);
					return;
				}

				// 有变化才写盘、才重启, 这一步由脚本判断; 页面按它给出的
				// "RESULT: ..." 结论决定提示什么。
				var kind = (String(out).match(/^RESULT:[ \t]*(\S+)/m) || [])[1] || '';

				return self.refreshList().then(function() {
					return self.reloadSource();
				}).then(function() {
					return self.handlePick(name);
				}).then(function() {
					if (kind === 'unchanged')
						self.setResult('ok', _('配置无变化, 未做改动'), out);
					else if (kind === 'updated-restarted')
						self.setResult('ok', _('已更新服务器和代理组, 并重启服务'), out + self.restartNote());
					else
						self.setResult('ok', _('已更新服务器和代理组'), out + self.restartNote());
				});
			}, function(e) {
				// 权限不足等 RPC 级失败走这里, 此时没有 code 可看
				self.setResult('err', _('更新无法执行'), String(e.message || e));
			});
		}, function(e) {
			self.setResult('err', _('读取 %s 失败').format(path), String(e.message || e));
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
			// 顶部「现为 %s」与列表里的当前配置标记同步更新
			var c = self.cfg();

			if (self.conffileInfo)
				self.conffileInfo.textContent = _('当前生效配置由 uci mihomo.main.conffile 指定 (与 /etc/init.d/mihomo 同源), 现为 %s。').format(c.conffile);

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

	// ---------------- 定时更新 (uci mihomo.autoupdate + autoupdate.sh) ----------------

	// uci 里的定时更新设置。autoupdate.sh 用 config_get 读同名的四项,
	// 所以这里的键名必须与脚本一致 (enabled / target / schedule / url)。
	// 只读不写: 写由 autoupdate.sh set 用命令行 uci 完成 (见该脚本的说明)。
	autoSettings: function() {
		return {
			enabled:  uci.get_first('mihomo', 'autoupdate', 'enabled') == '1',
			target:   uci.get_first('mihomo', 'autoupdate', 'target') || '',
			schedule: uci.get_first('mihomo', 'autoupdate', 'schedule') || AUTO_DEFAULT_SCHEDULE,
			url:      uci.get_first('mihomo', 'autoupdate', 'url') || ''
		};
	},

	// 与 autoupdate.sh 的 validate_schedule 保持一致, 先在页面上拦一次
	validSchedule: function(s) {
		if (!s || !/^[0-9*/, -]+$/.test(s))
			return false;

		return String(s).trim().split(/\s+/).length == 5;
	},

	// 目标下拉框与配置文件列表同源, 清单变化时同步刷新
	fillAutoTargets: function(entries) {
		var names = this.sortedNames(entries);
		var want = this.autoSettings().target;

		if (!this.autoTarget)
			return;

		while (this.autoTarget.firstChild)
			this.autoTarget.removeChild(this.autoTarget.firstChild);

		this.autoTarget.appendChild(E('option', { 'value': '' }, [ _('（请选择配置文件）') ]));

		for (var i = 0; i < names.length; i++) {
			this.autoTarget.appendChild(E('option', {
				'value': names[i].name,
				'selected': (names[i].name == want) ? '' : null
			}, [ names[i].name ]));
		}
	},

	// 用 uci 里的值初始化表单 (在目标下拉框填充之后调用)
	applyAutoSettings: function() {
		var s = this.autoSettings();
		var known = false;

		this.autoEnabled.checked = s.enabled;
		this.autoTarget.value = s.target;
		this.autoUrl.value = s.url;

		for (var i = 0; i < AUTO_SCHEDULES.length; i++) {
			if (AUTO_SCHEDULES[i][0] == s.schedule) {
				this.autoFreq.value = s.schedule;
				known = true;
				break;
			}
		}

		if (!known) {
			this.autoFreq.value = 'custom';
			this.autoCron.value = s.schedule;
		}

		this.autoScheduleSync();
	},

	// 「更新频率」选到自定义时展开 cron 输入框, 否则把选中的表达式写进去
	autoScheduleSync: function() {
		var custom = (this.autoFreq.value == 'custom');

		this.autoCron.style.display = custom ? 'inline-block' : 'none';

		if (!custom)
			this.autoCron.value = this.autoFreq.value;

		return Promise.resolve();
	},

	handleAutoFreq: function(ev) {
		return this.autoScheduleSync();
	},

	refreshAutoStatus: function() {
		var self = this;

		return fs.exec(AUTOUPDATE, [ 'status' ]).then(function(res) {
			if (self.autoStatusPre)
				self.autoStatusPre.textContent = joinOutput(res) || _('(无输出)');
		}, function(e) {
			if (self.autoStatusPre)
				self.autoStatusPre.textContent = String(e.message || e);
		});
	},

	handleAutoStatus: function(ev) {
		return this.refreshAutoStatus();
	},

	handleAutoSave: function(ev) {
		var self = this;
		var enabled = !!this.autoEnabled.checked;
		var target = String(this.autoTarget.value || '');
		var freq = String(this.autoFreq.value || '');
		var schedule = (freq == 'custom') ? String(this.autoCron.value || '').trim() : freq;
		var url = String(this.autoUrl.value || '').trim();

		if (enabled) {
			if (!target) {
				this.setResult('warn', _('请选择要定时更新的配置文件'), '');
				return Promise.resolve();
			}

			if (!this.validSchedule(schedule)) {
				this.setResult('warn', _('执行时间不合法'),
					_('需要 5 段 (分 时 日 月 周), 只能使用 0-9 * / , - 与空格, 例如 %s。当前值: %s')
						.format(AUTO_DEFAULT_SCHEDULE, schedule || '(空)'));
				return Promise.resolve();
			}
		}

		// 写 uci 与落计划任务都由 autoupdate.sh 完成。刻意不走 rpcd 的 uci.apply:
		// 那会发 config.change 事件, 使 mihomo 执行 reload (= stop + start),
		// 只改一个定时设置不该重启代理。
		this.setResult('info', _('正在保存定时设置…'), '', true);

		return fs.exec(AUTOUPDATE, [ 'set', enabled ? '1' : '0', target, schedule, url ])
			.then(function(res) {
				var ok = (res && res.code == 0);
				var out = joinOutput(res) || _('(无输出)');

				self.setResult(ok ? 'ok' : 'err',
					ok ? (enabled ? _('定时更新已启用') : _('定时更新已关闭'))
					   : _('定时设置未保存 (退出码 %s)').format(res ? res.code : '?'),
					out);

				return self.refreshAutoStatus();
			}, function(e) {
				self.setResult('err', _('保存定时设置失败'), String(e.message || e));
			});
	},

	handleAutoRemove: function(ev) {
		this.autoEnabled.checked = false;

		return this.handleAutoSave(ev);
	},

	// ---------------- 生命周期 ----------------

	load: function() {
		var self = this;

		return uci.load('mihomo').then(function() {
			return self.loadSources();
		}).then(function() {
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

		// ---- 仅更新表单 ----
		this.updInfo = E('div', {
			'style': 'margin:10px 0; padding:8px 10px; border-left:4px solid #1565c0; background:#e8f0fe; color:#0d47a1; border-radius:6px; font-size:0.92em;'
		}, [ '' ]);

		this.updUrl = E('input', {
			'type': 'text',
			'placeholder': _('留空则使用该配置记录的订阅链接'),
			'style': 'width:100%; padding:7px 8px; border:1px solid #e2e2e2; border-radius:6px; font-family:monospace;'
		}, []);

		// ---- 定时更新表单 ----
		this.autoEnabled = E('input', { 'type': 'checkbox' }, []);

		this.autoTarget = E('select', {
			'style': 'padding:7px 8px; border:1px solid #e2e2e2; border-radius:6px; background:#fff; font-family:monospace; min-width:180px;'
		}, []);

		this.autoFreq = E('select', {
			'style': 'padding:7px 8px; border:1px solid #e2e2e2; border-radius:6px; background:#fff;',
			'change': ui.createHandlerFn(self, 'handleAutoFreq')
		}, AUTO_SCHEDULES.map(function(item) {
			return E('option', { 'value': item[0] }, [ _(item[1]) ]);
		}));

		this.autoCron = E('input', {
			'type': 'text',
			'placeholder': AUTO_DEFAULT_SCHEDULE,
			'style': 'display:none; width:200px; padding:7px 8px; border:1px solid #e2e2e2; border-radius:6px; font-family:monospace;'
		}, []);

		this.autoUrl = E('input', {
			'type': 'text',
			'placeholder': _('留空则使用该配置记录的订阅链接'),
			'style': 'width:100%; padding:7px 8px; border:1px solid #e2e2e2; border-radius:6px; font-family:monospace;'
		}, []);

		this.autoStatusPre = E('pre', {
			'style': 'margin:10px 0 0 0; padding:10px; max-height:220px; overflow:auto; white-space:pre-wrap; word-break:break-all; background:#f6f6f6; border:1px solid #e2e2e2; border-radius:6px; font-size:0.9em; color:#333;'
		}, [ _('尚未读取定时更新状态') ]);

		var btn = function(label, handler, cls) {
			return E('button', {
				'class': 'btn cbi-button ' + (cls || 'cbi-button-apply'),
				'style': 'padding:7px 18px;',
				'click': ui.createHandlerFn(self, handler)
			}, [ label ]);
		};

		// 「当前生效配置」一行做成动态节点: 切换配置后立即改写, 不用手动刷新页面
		this.conffileInfo = E('span', {}, [
			_('当前生效配置由 uci mihomo.main.conffile 指定 (与 /etc/init.d/mihomo 同源), 现为 %s。').format(c.conffile)
		]);

		var root = E([
			E('h2', {}, [ _('配置文件') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('管理 %s 下的 clash/mihomo 配置文件: 远程导入订阅、选择运行哪一个、直接编辑内容。').format(c.workdir),
				E('br'),
				this.conffileInfo,
				E('br'),
				_('校验使用上游自带的 mihomo -t, 参数与服务启动一致; 保存与保存并重启都会先校验, 校验不通过不会写入文件。')
			]),

			// 注意: E([...]) 的数组项必须是节点, 不能塞 ''/null 等非节点值 ——
			// dom.create 会对它们走 createElement 从而抛 InvalidCharacterError,
			// 所以 "无提示" 的分支用空文档片段占位。
			(c.workdir == ACL_WORKDIR) ? E([]) : E('div', {
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

			E('h3', {}, [ _('仅更新服务器和代理组') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('按订阅链接重新拉取, 只替换选中配置里的 proxies (服务器) 与 proxy-groups (代理组) 两段; 其余设置 (rules / dns / tun 等) 以及手动修改过的内容都保持不动。'),
				E('br'),
				_('流程: 下载 → 提取两段 → 与本地对比 → mihomo -t 校验 → 通过才写回文件。任何一步失败都不会改动原文件, 并给出失败原因 (网络 / DNS 解析 / HTTP 状态 / 配置解析 / 校验不通过)。'),
				E('br'),
				_('两段内容与本地一致时不会写盘, 也不会重启服务; 只有内容确实变了才写入并重启 (仅当更新的正是当前生效的配置、且服务正在运行时)。')
			]),
			this.updInfo,
			E('div', { 'style': 'margin:10px 0 6px 0;' }, [ this.updUrl ]),
			E('div', { 'style': 'display:flex; gap:10px; flex-wrap:wrap; margin-bottom:6px;' }, [
				btn(_('仅更新'), 'handleUpdateCfg')
			]),

			E('h3', {}, [ _('定时更新服务器和代理组') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('启用后会写入一条计划任务 (cron), 按设定的频率对选中的配置文件执行与「仅更新」完全相同的流程: 下载订阅 → 只替换 proxies / proxy-groups 两段 → 与本地对比 → mihomo -t 校验 → 通过才写回文件。'),
				E('br'),
				_('内容与本地一致时什么都不做 (既不写盘也不重启); 内容有变化时更新配置并重启服务, 让新服务器立即生效。其余设置不会被改动; 每次结果与失败原因写入系统日志 (logread, 标签 mihomo-autoupdate)。'),
				E('br'),
				_('计划任务写在 /etc/crontabs/root 里由本页面管理的标记块中, 你自己添加的其它计划任务不受影响。')
			]),
			E('div', { 'style': 'display:flex; align-items:center; gap:18px; flex-wrap:wrap; margin:10px 0;' }, [
				E('label', { 'style': 'display:flex; align-items:center; gap:6px; color:#555;' }, [
					this.autoEnabled, _('启用定时更新')
				]),
				E('label', { 'style': 'display:flex; align-items:center; gap:6px; color:#555;' }, [
					_('目标配置'), this.autoTarget
				]),
				E('label', { 'style': 'display:flex; align-items:center; gap:6px; color:#555;' }, [
					_('更新频率'), this.autoFreq, this.autoCron
				])
			]),
			E('div', { 'style': 'margin:10px 0 6px 0;' }, [ this.autoUrl ]),
			E('div', { 'style': 'display:flex; gap:10px; flex-wrap:wrap;' }, [
				btn(_('保存定时设置'), 'handleAutoSave'),
				btn(_('关闭定时更新'), 'handleAutoRemove', 'cbi-button'),
				btn(_('刷新状态'), 'handleAutoStatus', 'cbi-button')
			]),
			this.autoStatusPre,

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
		this.syncSourceField(true);
		this.applyAutoSettings();
		this.refreshAutoStatus();

		if (data.error)
			this.setResult('err', _('读取目录 %s 失败').format(c.workdir), data.error, true);

		return root;
	},

	// 抑制 LuCI 默认的页脚保存/应用条
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
