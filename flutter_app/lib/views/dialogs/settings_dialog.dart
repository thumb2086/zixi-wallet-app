import 'package:flutter/material.dart';

import '../../l10n/translation.dart';
import '../../services/storage_service.dart';
import '../../update_service.dart';

Future<void> showSettingsDialog(
  BuildContext context, {
  required bool initialAutoUpdateEnabled,
  required AppLanguage currentLanguage,
  required Future<void> Function(AppLanguage language) onLanguageChanged,
  required ValueChanged<bool> onAutoUpdateChanged,
}) {
  bool autoUpdateEnabled = initialAutoUpdateEnabled;

  // ★ 2026-10-14：加入「立即檢查」
  //
  //   原本設定頁只有一個「自動檢查更新」的開關 —— 沒有任何方式能
  //   在使用者想確認的時候立刻查一次。使用者只能等自動檢查在
  //   下次啟動時（且未被節流擋下）才可能看到結果。
  //
  //   現在這顆按鈕帶 `force: true` 跳過節流，並依
  //   UpdateCheckResult 回報四種不同結果（含「已是最新」與「被限流」），
  //   不再是「按了沒反應，不知道成沒成功」。
  final updateService = GithubUpdateService();
  bool checking = false;

  return showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(T.of(context, 'settings')),
      content: StatefulBuilder(
        builder: (dialogContext, setDialogState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(T.of(context, 'auto_update_check')),
              value: autoUpdateEnabled,
              onChanged: (enabled) async {
                setDialogState(() {
                  autoUpdateEnabled = enabled;
                });
                await AppStorage.setAutoUpdateCheckEnabled(enabled);
                onAutoUpdateChanged(enabled);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: checking
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.system_update_alt),
              title: Text(
                checking
                    ? T.of(context, 'update_checking')
                    : T.of(context, 'update_check_now'),
              ),
              enabled: !checking,
              onTap: checking
                  ? null
                  : () async {
                      setDialogState(() => checking = true);
                      final result = await updateService.checkForUpdates(
                        dialogContext,
                        title: T.of(context, 'update_available'),
                        descriptionTemplate: T.of(context, 'update_desc'),
                        laterLabel: T.of(context, 'update_later'),
                        nowLabel: T.of(context, 'update_now'),
                        openFailedMessage: T.of(context, 'update_open_failed'),
                        // ★ 跳過節流 —— 使用者明確要求立刻查
                        force: true,
                      );
                      if (!dialogContext.mounted) return;
                      setDialogState(() => checking = false);
                      // 「已是最新」需要明確回報；限流的提示在
                      // checkForUpdates 內部已經用 SnackBar 顯示。
                      if (result == UpdateCheckResult.upToDate) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          SnackBar(
                            content:
                                Text(T.of(context, 'update_up_to_date')),
                          ),
                        );
                      }
                    },
            ),
            const Divider(),
            _languageTile(context, dialogContext, AppLanguage.system, T.of(context, 'lang_auto'),
                currentLanguage, onLanguageChanged),
            _languageTile(context, dialogContext, AppLanguage.zhTw, T.of(context, 'lang_zh_tw'),
                currentLanguage, onLanguageChanged),
            _languageTile(context, dialogContext, AppLanguage.zhCn, T.of(context, 'lang_zh_cn'),
                currentLanguage, onLanguageChanged),
            _languageTile(context, dialogContext, AppLanguage.en, T.of(context, 'lang_en'),
                currentLanguage, onLanguageChanged),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(T.of(context, 'close')),
        ),
      ],
    ),
  );
}

Widget _languageTile(
  BuildContext outerContext,
  BuildContext dialogContext,
  AppLanguage language,
  String label,
  AppLanguage currentLanguage,
  Future<void> Function(AppLanguage language) onLanguageChanged,
) {
  final isSelected = currentLanguage == language;
  return ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    leading: Icon(
      isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
    ),
    onTap: () async {
      if (isSelected) {
        Navigator.of(dialogContext).pop();
        return;
      }
      await onLanguageChanged(language);
      if (outerContext.mounted) {
        Navigator.of(dialogContext).pop();
      }
    },
  );
}
