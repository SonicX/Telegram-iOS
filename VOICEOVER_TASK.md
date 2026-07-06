# ТЗ: VoiceOver в чате — два нерешённых бага

Репозиторий: Swiftgram (форк Telegram-iOS), сборка через Bazel. Общение на русском.
Пользователь — незрячий, тестирует с включённым VoiceOver на iPhone 8 (iOS 16.7).

## Два бага, которые НЕ удалось починить (несколько итераций)

### Баг 1: при открытии чата курсор VO зачитывает соседние чаты
Пользователь активирует чат в списке. Пока новый экран чата грузится, курсор VoiceOver
успевает перескочить на соседние строки списка чатов и зачитать их, хотя на экране уже
открыт нужный чат. Вводит в заблуждение. Нужно: при переходе в чат запретить курсору
«улетать» в список чатов / случайные элементы.

### Баг 2: на последнем сообщении свайп уводит курсор в навбар вместо поля ввода
В чате И в комментариях: курсор на последнем (новейшем) сообщении, свайп вперёд одним
пальцем. Курсор должен встать на поле ввода текста с поднятием клавиатуры. По факту
улетает в заголовок чата (ChatTitleView) / навбар.

## Что уже сделано (НЕ работает, но логика близка — отталкивайтесь от логов, не переписывайте слепо)

Все правки НЕзакоммичены (последний коммит `d635d77c78`). Ключевые файлы:
- `submodules/Display/Source/ListView.swift` (+94 строки) — основная VO-машинерия
- `submodules/TelegramUI/Sources/ChatControllerNode.swift` (+41) — связка хуков с полем ввода
- `submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift` (+23)
- `submodules/ChatListUI/Sources/ChatListController.swift` (+13)

### По Багу 2 (последнее состояние)
В `ListView.advanceAtBoundaryIfNeeded` в САМОМ начале (до mutex-гейтов) добавлен хук
`accessibilityMoveFocusPastTrailingEdge: (() -> Bool)?`. Условие срабатывания:
`atEdge && voDirection > 0 && toIndex >= visibleCount-1`. ChatControllerNode связывает
его с `inputPanelNode.ensureFocused()`.

**ЧТО ПОКАЗАЛИ ЛОГИ (решающее):** хук СРАБАТЫВАЕТ — в логе есть
`[VO-STATE] boundary-trailing-focus -> input field`, и VO реально встаёт на
`ChatInputTextView`. НО затем фокус дрейфует:
```
focus-left-list type=ChatInputTextView   ← встал на поле ввода (хорошо)
focus-left-list type=ChatTitleView       ← уплыл в заголовок
recover-focus-triggered ...              ← наш же recover вернул фокус на сообщение
```
Виновник — `scheduleAccessibilityFocusContainmentCheck` / `recoverAccessibilityFocusToList`
в ListView.swift: они считают «фокус вне списка» и тянут курсор обратно.

Последняя попытка (тоже НЕ помогла): при trailing-focus ставится
`accessibilityIgnoreOffscreenUntil = +2.0с` и добавлена перепроверка этого окна ВНУТРИ
отложенного блока containment-check. Несмотря на это, в логе `recover-focus-triggered`
всё равно появляется.

#### Итерация (текущая сессия, НЕ проверена голосом) — две правки:
1. **Корень проблемы — фокус на поле ввода НЕ закрепляется.** В логе видно, что после
   `boundary-trailing-focus` курсор на миг встаёт на `ChatInputTextView`, потом
   `focus-scroll-triggered-by-index toIndex=3` (возврат к последнему сообщению) и затем
   дрейф в `ChatTitleView`. Причина: `becomeFirstResponder()` поднимает клавиатуру и
   пересобирает a11y-дерево в течение анимации (~0.3с), один ранний пост `.screenChanged`
   перебивается. **Фикс** в `ChatTextInputPanelNode.ensureFocused()`: добиваем фокус
   повторными постами на поле ввода на 0.35с и 0.65с (`.layoutChanged`, только пока input —
   firstResponder). Финальный пост после стабилизации дерева должен закрепиться.
2. **Глушим recover отдельным гейтом.** Добавлен `accessibilityTrailingFocusActiveUntil`
   (= now+3.0с при boundary-trailing-focus). Проверяется в `scheduleAccessibilityFocusContainmentCheck`
   (и при планировании, и внутри отложенного блока) — пока окно открыто, recover не
   планируется и не срабатывает. Это надёжнее, чем делить дедлайн с `ignoreOffscreenUntil`.

   Если в новом логе фокус ВСЁ ЕЩЁ дрейфует в `ChatTitleView` и остаётся там (без
   recover, т.е. recover успешно заглушён, но input не удержался) — значит keystone-фикс
   №1 не сработал; тогда пробовать: поднимать клавиатуру с ЗАДЕРЖКОЙ после первого поста
   фокуса, либо временно прятать последнее сообщение из a11y на время hand-off.

#### РЕШАЮЩИЙ диагноз (после `[VO-INPUT]` логов) — итерация N+2:
Гипотеза «невалидный фрейм поля ввода» ОПРОВЕРГНУТА: лог `[VO-INPUT] post … isFR=true
onScreen=true frame=66,433,244x31` — поле ввода валидно, первый ответчик, клавиатура
поднята (y 735→433). Посты `.screenChanged` на ввод СРАБАТЫВАЮТ (в логе
`focus-left-list type=ChatInputTextView`). **НО** сразу после идёт
`focus-scroll-triggered-by-index toIndex=3 localIndex=0 match=source-view` — список
комментариев СКРОЛЛИТ к своему последнему сообщению (оно геометрически у поля ввода) и
перетягивает курсор VO обратно на сообщение → дрейф в `ChatTitleView` → recover.
**Фикс:** в `handleSystemAccessibilityFocusNotification` (ListView.swift, сразу после
`reason=suspended`) добавлен ранний выход `reason=trailing-focus`, пока открыто окно
`accessibilityTrailingFocusActiveUntil` (3с). Это глушит и scroll-to-item, и планирование
recovery — список не мешает VO закрепиться на поле ввода. Серия из 5 постов в
`ensureFocused` сокращена до 2 (async0 + 0.4с), т.к. перетягивания больше нет.

#### ★ НАСТОЯЩИЙ КОРЕНЬ Бага 2 (итерация N+3) — структурный порядок дерева доступности:
Гейт `trailing-focus` отработал, посты на поле срабатывают (`focus-left-list
type=ChatInputTextView`), НО фокус всё равно уходит в навбар. Разбор иерархии в
`ChatControllerNode` setup (~стр. 943–976):
```
contentContainerNode.contentNode:  background → historyNodeContainer(СООБЩЕНИЯ) →
    floatingTopicsPanelContainer → navigationBar(ChatTitleView!) → navigateButtons
wrappingNode.contentNode:          inputContextPanelContainer → inputPanelContainerNode(ПОЛЕ ВВОДА)
```
**`navigationBar` (ChatTitleView) — прямой сосед historyNodeContainer в ТОМ ЖЕ контейнере,
добавлен сразу после него. Поле ввода — в другом, более позднем контейнере.** Повёрнутый
список (`rotated`) ломает геометрическую сортировку VO → «следующий элемент после
последнего сообщения» = навбар. ВОТ ПОЧЕМУ посты фокуса не держались: жест VO «вперёд»
встаёт на естественного соседа (навбар), перебивая наш пост. Мы боролись с ОС и проигрывали.
**Фикс (хирургический, бьёт в причину):** в `accessibilityMoveFocusPastTrailingEdge`
(ChatControllerNode) на время hand-off ставим `navigationBar.view.accessibilityElementsHidden
= true` — убираем конкурента, тогда «вперёд» от последнего сообщения идёт на поле ввода;
`ensureFocused()` закрепляет; через 2с навбар возвращаем. НЕ проверено голосом.
Если опять не сработает — следующий шаг: поле ввода всё равно не «следующий» в порядке;
тогда либо `accessibilityViewIsModal=true` на inputPanelContainer на время ввода (фокус-трап,
снимать при скрытии клавиатуры), либо переопределить `accessibilityElements` контейнера,
поставив inputPanel сразу после history (инвазивно, риск сломать рабочие VO-фичи).

#### ОТКАТ Бага 2 (по просьбе пользователя — фокус-трап «стало хуже»):
Все правки сессии по Багу 2 откачены: убраны `accessibilityViewIsModal`-трап и
`enableAccessibilityTrailingInputModal`/observer (ChatControllerNode), trailing-focus
гейты и флаг `accessibilityTrailingFocusActiveUntil` (ListView), мульти-пост и [VO-INPUT]
диагностика в `ensureFocused` (ChatTextInputPanelNode). Код Бага 2 вернулся к
прошлосессионному состоянию (boundary-хук + `ignoreOffscreenUntil +2.0` — «не работает, но
не мешает»). Решено сосредоточиться на Баге 1.

#### ★★ Баг 1 — ФИНАЛЬНЫЙ подход (список переиспользует машинерию истории):
Окна (0.7с, 2.0с) не справились: каскад возникает не только при материализации, но и
после `boundary-page-scroll` у края списка (свайп на крайнем элементе → silent-scroll →
re-anchor 49→42→35→28 → зачитывание чатов), уже ПОСЛЕ окна. Корень: ПЛОСКИЙ список чатов
зря использует VO-машинерию ПОВЁРНУТОЙ истории (scroll-to-focused + boundary-page-scroll).
**Финальный фикс** (флаг `accessibilityUsesNativeScrollForNonSequentialFocus`, только
ChatListNode): (1) scroll-to-focused срабатывает ТОЛЬКО для линейных ±1 переходов (ручная
навигация); нелинейные перескоки VO (re-anchor при появлении/после scroll/rotor) НЕ
подскролливаем — нативный VO сам прокрутит, каскад не запускается; (2) boundary-page-scroll
(`advanceAtBoundaryIfNeeded`) для списка отключён целиком (ранний `return false`). История
сообщений не затронута (флаг не выставлен). Time-window удалён. Логи:
`focus-scroll-suppressed-nonsequential`. НЕ проверено голосом.
Остаточный мелкий дрейф VO при появлении экрана (1-2 элемента) — iOS-нативное «осматривание»,
не убирается нашим кодом.

#### (архив) Баг 1 — подход с time-window (каскад при материализации списка):
Лог однозначно: при материализации списка чатов (`array-changed old=0 new=50`) VO садится
на последний элемент (`array-system-focus to=49`), наш обработчик скроллит к нему
(`focus-scroll-triggered-by-index`), VO перефокусируется на другой → снова скролл → каскад
`49→44→37→30` (`system-nonstep`), зачитывающий случайные чаты. Это ДО `peerSelected`, поэтому
синхронный suspend не успевает. Пользователь подтвердил: слышно «сразу при открытии чата».
**Фикс:** новый флаг `accessibilitySuppressMaterializationScrollCascade` (ListView, public),
включается ТОЛЬКО в `ChatListNode` (история не трогается). При `old==0 && new>0` открываем
окно 0.7с, в котором `scrollVoiceOverFocusToItem` НЕ вызывается (лог
`focus-scroll-suppressed-materialization`) — петля не запускается, курсор остаётся где VO его
поставил. Синхронный suspend в `peerSelected` оставлен (глушит список после тапа).
НЕ проверено голосом.

#### (архив) Итерация N+4: навбар-хайд НЕ помог → пробовали фокус-трап `accessibilityViewIsModal`
Скрытие навбара (`accessibilityElementsHidden`) с окном 2с не сработало: лог показал, что
дрейф в `ChatTitleView` и `recover` происходят ПОСЛЕ `navbar a11y restored` — time-window
(навбар 2с, гейт 3с) короче возни с клавиатурой на iPhone 8, после истечения список снова
скроллит к msg3, навбар восстановлен → дрейф. В конце лога мелькает
`focus-left-list type=UIAccessibilityElementKBKey` (клавиатура поднялась, VO дошёл до
клавиш) — т.е. конкурентов несколько и каждый переживает своё окно.
**Решение — НЕ time-window, а жёсткий OS-трап:** `enableAccessibilityTrailingInputModal()`
в ChatControllerNode ставит `inputPanelContainerNode.view.accessibilityViewIsModal = true`.
`inputPanelContainerNode` — сосед `contentContainerNode` под `wrappingNode`, поэтому VO
перестаёт видеть ВЕСЬ contentContainer (и список, и навбар), оставляя только панель ввода +
клавиатуру. Снимается по `keyboardWillHideNotification` (наблюдатель, removeObserver в deinit).
Навбар-хайд удалён. Логи: `[VO-INPUT] input-modal ON/OFF`. НЕ проверено голосом.
Риск: пока клавиатура поднята, VO не видит сообщения (это ожидаемо — «вы в поле ввода»;
чтобы вернуться к чтению — скрыть клавиатуру VO-escape, тогда модал снимется). **Гипотеза для новой сессии:** recover вызывается ещё одним путём
(не только через ignoreOffscreen-гейт), либо `ensureFocused()` поднимает клавиатуру, что
само пересобирает accessibility-дерево и сбрасывает фокус прежде, чем VO на нём
закрепится. Стоит проверить: (а) все вызовы `recoverAccessibilityFocusToList` и закрыть
ВСЕ пути при активном trailing-focus (отдельный bool-флаг `accessibilityTrailingFocusActive`,
сбрасываемый по таймеру ~1.5с, надёжнее чем ignoreOffscreenUntil); (б) поднимать
клавиатуру с задержкой ПОСЛЕ того как VO закрепился на поле, а не одновременно.

### По Багу 1 (последнее состояние)
В `ListView` добавлен флаг `accessibilityFocusHandlingSuspended: Bool` — при нём
`handleSystemAccessibilityFocusNotification` выходит рано (есть лог
`focus-handler-skip reason=suspended`). `ChatListController` ставит флаг `true` в
`viewWillDisappear` и `false` в `viewDidAppear` (через
`chatListDisplayNode.mainContainerNode.currentItemNode.accessibilityFocusHandlingSuspended`).
Также добавлен геометрический гейт: список игнорирует фокус, если его view не пересекает
окно.

**Почему не работает (гипотеза):** focus-события списка чатов идут ДО `viewWillDisappear`
(в момент тапа по чату и подготовки перехода список ещё топовый). В логе видно
`focus-scroll-triggered-by-index ... cursor='Аслан Нахушев' ... 'Роскосмос'` — это
прокрутка списка чатов с `cursor-log-source=system-nonstep` (VO сам перескакивает за
прокруткой), и всё это ДО `[VO-CHAT] full-materialisation toggled` (открытие чата).
**Для новой сессии:** перенести установку suspend-флага РАНЬШЕ — в момент выбора чата
(`peerSelected` / `navigateToPeer`), а не в `viewWillDisappear`. Также проверить по логам,
появляется ли вообще `focus-handler-skip reason=suspended` (если нет — флаг не доходит до
нужного listNode; список чатов может быть не `currentItemNode`, а другой контейнер при
наличии фильтров/папок).

#### Итерация (текущая сессия, НЕ проверена голосом):
Подтверждено по логу: в фазе открытия чата идут `focus-scroll-triggered-by-index toIndex=49…42…`
с `cursor='Архив чатов'/'Роскосмос'` (это СПИСОК чатов) и БЕЗ предшествующего
`focus-handler-skip reason=suspended` → флаг действительно ещё не стоял (viewWillDisappear
слишком поздно). **Фикс** в `ChatListController.peerSelected` (после раннего return для
inline-форума, перед `navigateToChatController`): ставим
`effectiveContainerNode.currentItemNode.accessibilityFocusHandlingSuspended = true` — но
только в compact-раскладке (в regular/iPad список не уходит и не получит viewDidAppear для
сброса). Сброс остаётся в `viewDidAppear` (`mainContainerNode.currentItemNode = false`;
при обычных фильтрах effective==main, один и тот же node). `viewWillDisappear` оставлен как
страховка. **Проверить в новом логе:** теперь в фазе открытия должно идти
`focus-handler-skip reason=suspended` вместо `focus-scroll-triggered-by-index` по чатам.

## Диагностика в коде (временная, убрать перед финальным коммитом)
`print("[VO-...]")` в: ListView.swift, NavigationController.swift, ChatTextInputPanelNode.swift,
ChatControllerOpenMessageReplies.swift (там `[VO-COMMENTS]`), ChatMessageBubbleItemNode.swift.
Это отладочные логи текущей сессии. Логи смотрит пользователь через Console.app по фильтру
`[VO-`.

## Баг 2 — РЕШЕНИЕ через кнопки тулбара (текущее, НЕ проверено голосом)
Виртуальный элемент, дописанный в массив истории, VO ПРОПУСКАЕТ (подтверждено логом:
`composeButton=true`, но курсор уходит с последнего сообщения сразу в навбар/поле, минуя
кнопку). Пуловая index-машинерия не ведёт на эфемерные элементы массива.
**Решение:** обе кнопки — настоящие `AccessibilityAreaNode` в тулбаре `ChatTextInputPanelNode`
(как рабочая «Закрыть»/`hideKeyboardAccessibilityArea`), VO до них доходит штатно:
- `composeAccessibilityArea` — «Написать сообщение»/«Добавить комментарий» (по
  `chatLocation .replyThread`), видна когда ввод доступен; activate → `ensureFocused()`.
- `cancelReplyForwardAccessibilityArea` — «Отменить ответ»/«Отменить пересылку» (по
  `interfaceState.replyMessageSubject`/`forwardMessageIds`), видна только при активной плашке;
  activate → `accessibilityCancelReplyForwardAction` (в ChatControllerNode: `accessoryPanelNode.dismiss()` + `ensureFocused`).
- Обе добавлены в `accessibilityElements` ПЕРВЫМИ (cancel, compose, затем textInput…), фрейм =
  `textInputAccessibilityFrame`, `isHidden` управляет видимостью.
- Виртуальные кнопки из истории УДАЛЕНЫ. Также удалён баг: `accessibilityIsLegitimateFocusEscape`
  больше НЕ вызывает `ensureFocused()` (из-за этого курсор прилипал к полю при попытке уйти на тулбар).

## Баг 2 — ФИНАЛ: реальный пуловый элемент в ленте (Вариант B, НЕ проверено голосом)
Тулбар-`AccessibilityAreaNode` тоже оказались недостижимы (лог: курсор бьётся между
`ChatInputTextView`/`View`, до зон не доходит). Подтверждено: VO-стопом в истории может быть
ТОЛЬКО элемент того же пулового типа, что сообщения (`FocusTrackingAccessibilityElement` с
sourceView + localIndex). Реализовано:
- `ListView`: `accessibilityTrailingPooledElementsProvider` + публичная
  `ListViewAccessibilityTrailingElement` (Accessibility.swift). В directional-ветке
  `customAccessibilityElements` синтетические элементы получают `localIndex = min-1, min-2`
  → после reverse становятся последними стопами. `accessibilitySyntheticTrailingIndices`
  гейтит `scrollVoiceOverFocusToItem` (скроллить к ним некуда).
  `accessibilitySuppressTrailingBoundaryScroll` включается при их наличии.
- `ChatHistoryListNode`: невидимые `ChatHistoryTrailingActionView` (их `accessibilityActivate`
  дёргается из пулового элемента → действие), провайдер строит элементы с фреймом-полоской
  44pt у нижней кромки списка, подписи/видимость из *ButtonInfo-замыканий.
- `ChatControllerNode`: *ButtonInfo/*Activate на historyNode (compose → ensureFocused;
  cancel → accessoryPanelNode.dismiss + ensureFocused).
- Тулбар-кнопки убраны из `accessibilityElements` панели (дормант).
Если VO теперь доходит до кнопок в ленте — Баг 2 закрыт.

## Контекст по архитектуре VoiceOver в истории чата (ВАЖНО)
Подробности в памяти: `voiceover-chat-history-focus-machinery.md`. Кратко:
- История чата (`ChatHistoryListNodeImpl: ListView`) использует НЕстандартную index-driven
  пуловую focus-машинерию в `ListView.swift`, НЕ обычный массив accessibilityElements.
- `rotated=true` + `accessibilityNavigationOrder=.reversed`: новейшее сообщение визуально
  снизу, у поля ввода; в массиве это последний индекс, движение к нему = `voDirection > 0`.
- Глобальный NotificationCenter-обработчик `handleSystemAccessibilityFocusNotification`
  (ListView.swift) получают ВСЕ ListView одновременно — отсюда конфликты между экранами.

## Как собирать (debug на устройство)
Подпись и сборка задокументированы в памяти `testflight-build-signing.md`. Кратко:
```
# dev-папка подписи (профили из репо, ключ локально):
mkdir -p /tmp/tg-cs-dev/profiles /tmp/tg-cs-dev/certs
cp build-system/codesigning-dev/profiles/Telegram.mobileprovision /tmp/tg-cs-dev/profiles/
cp build-system/codesigning-dev/profiles/TelegramNotification.mobileprovision /tmp/tg-cs-dev/profiles/
cp build-system/codesigning-dev/certs/ios_development.cer /tmp/tg-cs-dev/certs/
python3 -c "import json;d=json.load(open('build-system/configuration.json'));d['telegram_use_xcode_managed_codesigning']=False;json.dump(d,open('/tmp/tg-cs-dev/configuration.json','w'),indent=4)"
# сборка (инкрементальная — пара минут):
python3 build-system/Make/Make.py --overrideXcodeVersion build \
  --configurationPath=/tmp/tg-cs-dev/configuration.json \
  --codesigningInformationPath=/tmp/tg-cs-dev \
  --configuration=debug_arm64 --buildNumber=32094 \
  --outputBuildArtifactsPath=testflight-build/debug-artifacts
```
Результат: `testflight-build/debug-artifacts/Swiftgram.ipa`. dev-профили содержат UDID
устройства (66c3da5e…), ставится на устройство. xcode_version 26.0.1 в проекте vs 26.5 на
машине → нужен `--overrideXcodeVersion`.

## Что уже РАБОТАЕТ в этой сессии (не сломать!)
- VO-действия в меню сообщения: «Комментарии», «Реакции» (через рамку open-context-menu),
  «Ответить»/«Переслать» с фокусом на поле ввода.
- 3-пальцевый скролл озвучивает дату верхнего видимого сообщения.
- Контекстное меню фокусируется на первом пункте; реакции — на первой реакции.
- Forward → переход в чат с автофокусом на поле ввода.
- Крестик отмены ответа/пересылки доступен VO.

## Рабочий процесс
1. Не чинить вслепую — каждая правка проверяется СБОРКОЙ + голосом на устройстве, логи
   присылает пользователь.
2. Перед сборкой проверять баланс скобок (python: `d.count('{')-d.count('}')`).
3. Сборка долгая, читать файлы точечно.
4. Пользователь предпочитает русский.
