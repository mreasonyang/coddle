(() => {
  'use strict';
  const translations = {
    zh: {
      skip: '跳到正文', navFeatures: '功能', navFaq: '常见问题', navDownload: '获取 Coddle',
      eyebrow: 'macOS 原生菜单栏工具', heroOne: '有度充电，', heroTwo: '从容运行',
      heroDescription: '在支持的 Mac 上设置 80–100% 充电上限，使用本地智能充电，并为长任务防止自动休眠。都在菜单栏，随手可控。',
      heroDownload: '下载 macOS 预览版', heroExplore: '了解功能', heroNote: '免费开源 · 为 macOS 而作 · 无需注册', heroCaption: '控制清晰，少些打扰',
      careNote: '一点点照顾，<br>陪你更久一点', panelAlt: 'Coddle 应用界面，展示电池状态、80% 充电上限、功率流向和防止休眠控制', screenshotCaption: '实际应用界面 · 示例数据',
      floatTitle: '刚刚好，就很好', floatText: '设好上限，安心投入',
      qualityOne: '熟悉的 Mac 原生体验', qualityTwo: '你的习惯，留在本机', qualityThree: '独立设置，清晰控制', qualityFour: '免费，自由，开源',
      rhythmEyebrow: '01 / 找到你的节奏', rhythmTitle: '每一种日常，', rhythmEm: '都有合适的节奏',
      rhythmDescription: '在桌前设好充电上限，出门前按需补电，或让 Mac 在长任务期间保持运行。',
      tabDesk: '坐在桌前', tabGo: '准备出门', tabFocus: '长任务运行', demoLabel: '交互演示', demoLimit: '试着调整充电上限',
      focusPreview: 'Mac 继续运行，屏幕安心休息', demoDisclaimer: '仅为交互示意，不会更改你的 Mac 设置。',
      detailsEyebrow: '02 / 安静，却很能干', detailsTitle: '少一点打扰，', detailsEm: '多一点周到',
      detailOneTitle: '查看电池与供电状态', detailOneDescription: '电量、健康度、循环次数、温度和功率流向，集中在菜单栏面板中，一眼掌握。', detailOneFoot: '轻轻一瞥，心里有数。',
      detailTwoTitle: '本地智能充电，契合日常', detailTwoDescription: '根据本机插电记录预估拔电时间：平时保持充电上限，在预计拔电前允许补电。', detailTwoFoot: '本地规则，无需云端模型。',
      detailThreeTitle: '让长任务，继续往前', detailThreeDescription: '构建、导出，或让 Agent 持续工作。保持 Mac 运行，并分别选择屏幕常亮和合盖运行。', detailThreeFoot: '合盖运行需单独安装可选特权辅助组件。',
      localTitle: '你的 Mac，由你做主', localDescription: '设置和充电习惯保存在本机。无需账户，没有订阅。六种应用语言、两套外观，以及随时可以调整的选择。', localSeal: '熟悉，自然<br>就像本来如此',
      faqEyebrow: '03 / 你可能想知道', faqTitle: '先了解，再开始', faqDescription: '了解兼容性、所需权限，以及预览版的使用说明。',
      faqOneQ: '我的 Mac 可以使用吗？', faqOneA: 'Universal 下载包包含 Apple Silicon 和 Intel 两种架构，最低构建目标为 macOS 13。限充支持因机型和系统而异，Coddle 会在运行时检查可用能力。目前已在近期 macOS 的 Apple Silicon Mac 上进行真机验证；Intel 和较旧 macOS 的运行测试尚未完成。',
      faqTwoQ: '这是正式发布的版本吗？', faqTwoA: '目前是免费提供的早期预览版，使用 ad-hoc 签名，尚未进行 Developer ID 签名或 Apple 公证。macOS 可能阻止它正常打开。请先阅读安装说明并查看源码，再决定是否使用。',
      faqThreeQ: '需要管理员权限吗？', faqThreeA: '限充与普通防止休眠无需特权辅助组件。合盖运行需要可选辅助组件，只有你主动选择安装并完成 macOS 管理员授权后才会安装。部分系统电源模式更改也需要授权。',
      faqFourQ: '关闭防止休眠后，会发生什么？', faqFourA: '关闭“防止休眠”总开关后，Coddle 会停止它管理的电脑、屏幕和合盖保活。屏幕与合盖偏好会保留，供下次使用；充电设置与系统屏幕休眠时间不变。如果无法确认保活已停止，应用会显示状态并重试。',
      faqFiveQ: '智能充电会使用云端 AI 或上传数据吗？', faqFiveA: '它通过本机按小时记录的插电样本和简单规则工作，不使用在线 AI 模型。需要积累足够记录才能识别习惯，预测并非保证。配置和充电习惯均保存在你的 Mac 上。',
      faqSixQ: 'Coddle 开源吗？', faqSixA: '是的。Coddle 采用 MIT 许可证。你可以下载与预览版对应的源码快照，查看实现或自行构建。', sourceLink: '获取源码 ↗',
      downloadEyebrow: '准备好开始了吗？', downloadTitle: '给你的 Mac，', downloadEm: '更合适的节奏', downloadDescription: '试用免费开源的预览版，管理充电上限、本地智能充电与长任务防休眠。',
      downloadButton: '下载 macOS 预览版', downloadMeta: 'v0.1.0 预览版 · Universal（Apple Silicon / Intel）· 最低构建目标 macOS 13 · 约 3.0 MB', downloadCaveat: '采用 ad-hoc 临时签名，未经 Apple 公证，macOS 可能阻止打开；请先阅读安装指引。限充支持因机型和系统而异。',
      installLink: '安装指引 ↗', sourceShort: '源代码 ↗', checksumLink: 'SHA-256 校验值 ↗', footerNote: '给你的 Mac，一点点照顾', privacyLink: '隐私说明', footerSource: '开放源代码 ↗'
    }
  };
  const originals = new Map();
  const nodes = [...document.querySelectorAll('[data-i18n]')];
  nodes.forEach(node => originals.set(node, node.innerHTML));
  let language;
  try { language = localStorage.getItem('coddle-language'); } catch {}
  if (!['en', 'zh'].includes(language)) language = navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en';
  let scenario = 'desk';
  let chosenLimit = 80;
  const scenarioCopy = {
    en: {
      desk: ['Holding steady', 'A limit that feels right', 'Choose an 80–100% charge limit on supported Macs. Keep a little headroom while you stay plugged in.'],
      go: ['Top up before unplugging', 'Charge up before you go', 'Choose Charge to Full Now to allow a top-up, or let local smart charging estimate your unplug time and allow charging beforehand.'],
      focus: ['Prevent automatic sleep', 'Keep your Mac awake', 'Prevent automatic sleep during builds, exports, or agent runs while letting your display follow its normal sleep timer.']
    },
    zh: {
      desk: ['稳稳保持', '一个刚刚好的上限', '在支持的 Mac 上选择 80–100% 的充电上限。长时间插电，也给电池留一点余地。'],
      go: ['出发前补电', '出门之前，按需补电', '选择“立即充满”来允许补电，或让本地智能充电根据日常习惯预估拔电时间，提前允许充电。'],
      focus: ['防止自动休眠', 'Mac 持续运行，屏幕正常休眠', '在构建、导出或 Agent 任务期间防止 Mac 自动休眠，同时允许屏幕按系统设定正常熄灭。']
    }
  };
  function updateScenario() {
    const panel = document.getElementById('scenario-panel');
    if (!panel) return;
    const copy = scenarioCopy[language][scenario];
    document.getElementById('demo-status-text').textContent = copy[0];
    for (const [id, text] of [['scenario-title', copy[1]], ['scenario-description', copy[2]]]) {
      const node = document.getElementById(id);
      if (node.textContent !== text) node.textContent = text;
    }
    document.getElementById('charge-limit').setAttribute('aria-valuetext', `${chosenLimit}%`);
    const value = scenario === 'go' ? 100 : chosenLimit;
    document.getElementById('battery-number').innerHTML = `${value}<span>%</span>`;
    document.getElementById('battery-fill').style.width = `${value}%`;
    document.getElementById('limit-control').hidden = scenario !== 'desk';
    document.getElementById('focus-preview').hidden = scenario !== 'focus';
    panel.setAttribute('aria-labelledby', `tab-${scenario}`);
    document.querySelectorAll('[data-scenario]').forEach(button => {
      const active = button.dataset.scenario === scenario;
      button.setAttribute('aria-selected', String(active));
      button.tabIndex = active ? 0 : -1;
    });
  }
  function setLanguage(next) {
    language = next;
    document.documentElement.lang = language === 'zh' ? 'zh-CN' : 'en';
    nodes.forEach(node => { node.innerHTML = language === 'zh' && translations.zh[node.dataset.i18n] ? translations.zh[node.dataset.i18n] : originals.get(node); });
    document.querySelectorAll('[data-i18n-alt]').forEach(node => {
      if (!node.dataset.englishAlt) node.dataset.englishAlt = node.alt;
      node.alt = language === 'zh' ? translations.zh[node.dataset.i18nAlt] : node.dataset.englishAlt;
    });
    document.querySelectorAll('[data-locale]').forEach(node => { node.hidden = node.dataset.locale !== (language === 'zh' ? 'zh-CN' : 'en'); });
    const button = document.getElementById('language');
    if (button) {
      button.innerHTML = `${language === 'zh' ? 'EN' : '中文'} <span aria-hidden="true">↗</span>`;
      button.setAttribute('aria-label', language === 'zh' ? 'Switch to English' : '切换为中文');
    }
    if (document.getElementById('hero-title')) {
      document.title = language === 'zh' ? 'Coddle — 给你的 Mac，一点点照顾' : 'Coddle — A little care for your Mac';
      document.querySelector('meta[name="description"]').content = language === 'zh' ? 'Coddle 是一款原生 macOS 菜单栏工具，提供充电上限、智能充电和防止休眠。了解功能，下载免费预览版。' : 'A macOS menu bar utility for charge limits on supported Macs, local smart charging, and sleep prevention. Download the free, open-source preview.';
    }
    try { localStorage.setItem('coddle-language', language); } catch {}
    updateScenario();
  }
  document.getElementById('language')?.addEventListener('click', () => setLanguage(language === 'en' ? 'zh' : 'en'));
  const tabs = [...document.querySelectorAll('[data-scenario]')];
  tabs.forEach((button, index) => {
    button.addEventListener('click', () => { scenario = button.dataset.scenario; updateScenario(); });
    button.addEventListener('keydown', event => {
      const keys = ['ArrowLeft', 'ArrowRight', 'Home', 'End'];
      if (!keys.includes(event.key)) return;
      event.preventDefault();
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : (index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
      tabs[next].focus(); tabs[next].click();
    });
  });
  document.getElementById('charge-limit')?.addEventListener('input', event => { chosenLimit = Number(event.target.value); updateScenario(); });
  setLanguage(language);
})();
