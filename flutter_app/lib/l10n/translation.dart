import 'package:flutter/material.dart';

enum AppLanguage { system, zhTw, zhCn, en }

extension AppLanguageTag on AppLanguage {
  String get tag {
    switch (this) {
      case AppLanguage.system:
        return 'system';
      case AppLanguage.zhTw:
        return 'zh-TW';
      case AppLanguage.zhCn:
        return 'zh-CN';
      case AppLanguage.en:
        return 'en';
    }
  }

  static AppLanguage fromTag(String tag) {
    switch (tag) {
      case 'zh-TW':
        return AppLanguage.zhTw;
      case 'zh-CN':
        return AppLanguage.zhCn;
      case 'en':
        return AppLanguage.en;
      default:
        return AppLanguage.system;
    }
  }
}

class T {
  static final Map<String, Map<String, String>> _values = {
    'en': {
      'token_symbol': 'ZHIXI',
      'loading': 'Loading...',
      'app_dashboard_title': 'D-Linker Dashboard',
      'my_assets': 'My Assets',
      'balance_format': '{1} {2}',
      'device_wallet_address': 'Device Wallet Address',
      'copy_success': 'Copied successfully',
      'receive': 'Receive',
      'wallet_auth': 'Wallet Auth',
      'scan': 'Scan',
      'transfer': 'Transfer',
      'migration': 'Device Migration',
      'request_test_coins': 'Get Test Coins ({1})',
      'airdrop_request_sent': 'Airdrop request sent',
      'failure_message': 'Failure: {1}',
      'update_available': 'Update Available',
      'update_desc': 'A new version ({1}) is available.',
      'update_later': 'Later',
      'update_now': 'Update Now',
      'update_open_failed': 'Unable to open update page',
      'auto_update_check': 'Auto Check Updates',
    'update_check_now': 'Check Now',
    'update_checking': 'Checking…',
    'update_up_to_date': 'You are on the latest version',
    'update_rate_limited': 'Update check rate limited by GitHub — will retry later',
      'session_required': 'Please complete Wallet Auth first',
      'casino': 'Casino',
      'manual_address_input': 'Enter Address Manually',
      'address_placeholder': '0x...',
      'cancel': 'Cancel',
      'confirm': 'Confirm',
      'send_symbol': 'Send {1}',
      'to_address': 'To: {1}',
      'amount': 'Amount',
      'confirm_send': 'Confirm Send',
      'transfer_success': 'Transfer successful!',
      'receive_address': 'Receive Address',
      'close': 'Close',
      'camera_permission_required': 'Camera permission is required',
      'migration_title': 'Full Device Migration',
      'migration_desc':
          'Private key cannot be exported from hardware security module. Transfer all assets to the new device address.',
      'migration_confirm': 'Confirm Transfer All Balance',
      'settings': 'Settings',
      'lang_auto': 'System Default',
      'lang_zh_tw': 'Traditional Chinese',
      'lang_zh_cn': 'Simplified Chinese',
      'lang_en': 'English',
      'transaction_history': 'Transaction History',
      'tx_send': 'Send',
      'tx_receive': 'Receive',
      'tx_no_history': 'No transaction history yet',
      'auth_confirm_title': 'Wallet Auth Request',
      'auth_confirm_desc':
          'The web app requests wallet linking.\n\nSession ID: {1}\nAddress: {2}',
      'auth_confirm_button': 'Authorize',
      'auth_external_warning': 'This request came from an external app or webpage. Only approve if you initiated this action.',
      'auth_success_return': 'Authorization complete. You can return to web.',
      'manual_code_entry': 'Manual Code',
      'manual_code_hint': 'Paste session_xxx or dlinker:login:xxx',
      'manual_code_error': 'Invalid authorization code format',
      'bet_confirm_title': 'Bet Signature Request',
      'bet_confirm_desc': 'Game: {1}\nSide: {2}\nAmount: {3} {4}',
      'bet_confirm_button': 'Sign & Submit Bet',
      'bet_success': 'Bet request submitted',
      'contacts': 'Contacts',
      'select_contact': 'Select Contact',
      'no_contacts': 'No contacts yet',
      'add_contact': 'Add Contact',
      'contact_name': 'Name',
      'wallet_address': 'Wallet Address',
      'pin_setup_title': 'Set Security PIN',
      'pin_setup_desc': 'Secure storage is unavailable. Please set a 6-digit PIN to encrypt your private key.',
      'pin_enter': 'Enter PIN',
      'pin_confirm': 'Confirm PIN',
      'pin_unlock_title': 'Enter PIN',
      'pin_unlock_desc': 'Enter your 6-digit PIN to unlock wallet',
      'pin_mismatch': 'PIN does not match',
      'pin_invalid': 'PIN must be exactly 6 digits',
      'pin_incorrect': 'Incorrect PIN',
      'pin_timeout': 'Session timed out. Please re-enter your PIN.',
      'convert': 'Convert to YJC',
      'convert_desc': 'ZXC balance: {1}. Enter ZXC amount to convert to YJC:',
      'convert_confirm': 'Convert',
      'convert_success': 'Conversion successful!',
    },
    'zh_TW': {
      'token_symbol': '子熙幣',
      'loading': '載入中...',
      'app_dashboard_title': 'D-Linker 儀表板',
      'my_assets': '我的資產',
      'balance_format': '{1} {2}',
      'device_wallet_address': '設備錢包地址',
      'copy_success': '複製成功',
      'receive': '收款',
      'wallet_auth': '錢包授權',
      'scan': '掃描',
      'transfer': '轉帳',
      'migration': '設備轉移',
      'request_test_coins': '領取測試幣（{1}）',
      'airdrop_request_sent': '入金請求已送出',
      'failure_message': '失敗: {1}',
      'update_available': '有新版本可更新',
      'update_desc': '偵測到新版本（{1}），請更新。',
      'update_later': '稍後',
      'update_now': '立即更新',
      'update_open_failed': '無法開啟更新頁面',
      'auto_update_check': '自動檢查更新',
    'update_check_now': '立即檢查',
    'update_checking': '檢查中…',
    'update_up_to_date': '已是最新版本',
    'update_rate_limited': 'GitHub 查詢頻率受限，稍後自動再試',
      'session_required': '請先完成錢包授權',
      'casino': '賭場',
      'manual_address_input': '手動輸入地址',
      'address_placeholder': '0x...',
      'cancel': '取消',
      'confirm': '確定',
      'send_symbol': '發送 {1}',
      'to_address': '至: {1}',
      'amount': '金額',
      'confirm_send': '確認發送',
      'transfer_success': '轉帳成功！',
      'receive_address': '收款地址',
      'close': '關閉',
      'camera_permission_required': '請授予相機權限',
      'migration_title': '全額設備轉移',
      'migration_desc': '請將所有資產轉移至新設備地址。',
      'migration_confirm': '確認轉移全部餘額',
      'settings': '設定',
      'lang_auto': '跟隨系統',
      'lang_zh_tw': '繁體中文',
      'lang_zh_cn': '簡體中文',
      'lang_en': 'English',
      'transaction_history': '交易紀錄',
      'tx_send': '轉出',
      'tx_receive': '轉入',
      'tx_no_history': '目前尚無交易紀錄',
      'auth_confirm_title': '授權登入請求',
      'auth_confirm_desc': '網頁端請求連結您的錢包。\n\nSession ID: {1}\n地址: {2}',
      'auth_confirm_button': '確認授權',
      'auth_external_warning': '此請求來自外部應用程式或網頁。請只在您確實要進行此操作時才批准。',
      'auth_success_return': '授權成功，可返回網頁',
      'manual_code_entry': '輸入授權碼',
      'manual_code_hint': '貼上 session_xxx 或 dlinker:login:xxx',
      'manual_code_error': '授權碼格式錯誤',
      'bet_confirm_title': '下注簽名請求',
      'bet_confirm_desc': '遊戲: {1}\n選擇: {2}\n金額: {3} {4}',
      'bet_confirm_button': '確認下注並簽名',
      'bet_success': '下注請求已送出',
      'contacts': '通訊錄',
      'select_contact': '選擇聯絡人',
      'no_contacts': '目前尚無聯絡人',
      'add_contact': '新增聯絡人',
      'contact_name': '姓名',
      'wallet_address': '錢包地址',
      'pin_setup_title': '設定安全 PIN 碼',
      'pin_setup_desc': '安全儲存不可用。請設定 6 位數 PIN 碼來加密您的私鑰。',
      'pin_enter': '輸入 PIN 碼',
      'pin_confirm': '確認 PIN 碼',
      'pin_unlock_title': '輸入 PIN 碼',
      'pin_unlock_desc': '輸入您的 6 位數 PIN 碼以解鎖錢包',
      'pin_mismatch': 'PIN 碼不一致',
      'pin_invalid': 'PIN 碼必須為 6 位數字',
      'pin_incorrect': 'PIN 碼錯誤',
      'pin_timeout': '連線逾時，請重新輸入 PIN 碼。',
      'convert': '兌換成 YJC',
      'convert_desc': 'ZXC 餘額：{1}。輸入要兌換成 YJC 的 ZXC 數量：',
      'convert_confirm': '兌換',
      'convert_success': '兌換成功！',
    },
    'zh_CN': {
      'token_symbol': '子熙币',
      'loading': '加载中...',
      'app_dashboard_title': 'D-Linker 仪表板',
      'my_assets': '我的资产',
      'balance_format': '{1} {2}',
      'device_wallet_address': '设备钱包地址',
      'copy_success': '复制成功',
      'receive': '收款',
      'wallet_auth': '钱包授权',
      'scan': '扫描',
      'transfer': '转账',
      'migration': '设备转移',
      'request_test_coins': '领取测试币（{1}）',
      'airdrop_request_sent': '入金请求已发送',
      'failure_message': '失败: {1}',
      'update_available': '有新版本可更新',
      'update_desc': '检测到新版本（{1}），请更新。',
      'update_later': '稍后',
      'update_now': '立即更新',
      'update_open_failed': '无法打开更新页面',
      'auto_update_check': '自动检查更新',
    'update_check_now': '立即检查',
    'update_checking': '检查中…',
    'update_up_to_date': '已是最新版本',
    'update_rate_limited': 'GitHub 查询频率受限，稍后自动重试',
      'session_required': '请先完成钱包授权',
      'casino': '赌场',
      'manual_address_input': '手动输入地址',
      'address_placeholder': '0x...',
      'cancel': '取消',
      'confirm': '确定',
      'send_symbol': '发送 {1}',
      'to_address': '至: {1}',
      'amount': '金额',
      'confirm_send': '确认发送',
      'transfer_success': '转账成功！',
      'receive_address': '收款地址',
      'close': '关闭',
      'camera_permission_required': '请授予相机权限',
      'migration_title': '全额设备转移',
      'migration_desc': '请将所有资产转移至新设备地址。',
      'migration_confirm': '确认转移全部余额',
      'settings': '设置',
      'lang_auto': '跟随系统',
      'lang_zh_tw': '繁体中文',
      'lang_zh_cn': '简体中文',
      'lang_en': 'English',
      'transaction_history': '交易纪录',
      'tx_send': '转出',
      'tx_receive': '转入',
      'tx_no_history': '目前尚无交易纪录',
      'auth_confirm_title': '授权登录请求',
      'auth_confirm_desc': '网页端请求链接您的钱包。\n\nSession ID: {1}\n地址: {2}',
      'auth_confirm_button': '确认授权',
      'auth_external_warning': '此请求来自外部应用或网页。请只在您确实要进行此操作时才批准。',
      'auth_success_return': '授权成功，可返回网页',
      'manual_code_entry': '输入授权码',
      'manual_code_hint': '粘贴 session_xxx 或 dlinker:login:xxx',
      'manual_code_error': '授权码格式错误',
      'bet_confirm_title': '下注签名请求',
      'bet_confirm_desc': '游戏: {1}\n选择: {2}\n金额: {3} {4}',
      'bet_confirm_button': '确认下注并签名',
      'bet_success': '下注请求已发送',
      'contacts': '通讯录',
      'select_contact': '选择联系人',
      'no_contacts': '目前尚无联系人',
      'add_contact': '新增联系人',
      'contact_name': '姓名',
      'wallet_address': '钱包地址',
      'pin_setup_title': '设置安全 PIN 码',
      'pin_setup_desc': '安全存储不可用。请设置 6 位数 PIN 码来加密您的私钥。',
      'pin_enter': '输入 PIN 码',
      'pin_confirm': '确认 PIN 码',
      'pin_unlock_title': '输入 PIN 码',
      'pin_unlock_desc': '输入您的 6 位数 PIN 码以解锁钱包',
      'pin_mismatch': 'PIN 码不一致',
      'pin_invalid': 'PIN 码必须为 6 位数字',
      'pin_incorrect': 'PIN 码错误',
      'pin_timeout': '连接超时，请重新输入 PIN 码。',
      'convert': '兑换成 YJC',
      'convert_desc': 'ZXC 余额：{1}。输入要兑换成 YJC 的 ZXC 数量：',
      'convert_confirm': '兑换',
      'convert_success': '兑换成功！',
    },
  };

  static String of(BuildContext context, String key, [List<String> args = const []]) {
    final locale = Localizations.localeOf(context);
    final localeCode = _localeCode(locale);
    final template = _values[localeCode]?[key] ?? _values['en']?[key] ?? key;

    var result = template;
    for (var i = 0; i < args.length; i++) {
      result = result.replaceAll('{${i + 1}}', args[i]);
    }
    return result;
  }

  static String _localeCode(Locale locale) {
    if (locale.languageCode == 'zh') {
      final country = (locale.countryCode ?? '').toUpperCase();
      final script = (locale.scriptCode ?? '').toLowerCase();
      if (country == 'CN' || script == 'hans') {
        return 'zh_CN';
      }
      return 'zh_TW';
    }
    return 'en';
  }
}
