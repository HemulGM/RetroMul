# RetroAchievements на Delphi

Нативный перенос rcheevos 12.5.0. RetroMul использует эти Pascal-модули напрямую:
адаптер `RA.GBA` создаёт `TRASession`, а сетевой обмен выполняет `TRAHttpClient`
через стандартный Delphi HTTP-клиент.

| Задача | Модули |
| --- | --- |
| Клиент, вход, сессия, запросы и события | `RA.Session`, `RA.Http`, `RA.Protocol`, `RA.Info`, `RA.GameData`, `RA.Editor` |
| Условия, достижения и рекорды | `RA.Conditions`, `RA.Trigger`, `RA.Value`, `RA.Leaderboards`, `RA.Runtime`, `RA.Validate` |
| Rich Presence и форматирование | `RA.RichPresence`, `RA.Format` |
| Сохранение прогресса | `RA.Progress`, `RA.RCheevosProgress` |
| Хеширование ROM, дисков и архивов | `RA.Hash`, `RA.MediaHash`, `RA.DiscHash`, `RA.CDReader`, `RA.ArchiveHash`, `RA.Hash3DS` |
| Память и консоли | `RA.Memory`, `RA.MemoryValues`, `RA.Console`, `RA.LibretroMemory`, `RA.LibretroPolicy`, `RA.LibretroHashSet` |
| Расчёт размера C-совместимых определений | `RA.DefinitionSize`, `RA.DefinitionLayout` |

Эмуляторные адаптеры и настройки аккаунта находятся в `source/achievements`.
Классы и управляемые записи заменяют C-модель владения памятью; соответствия
публичного API перечислены в `codex-work/ra-delphi/PublicAPIMapping.md`.

`RA.DefinitionSize` возвращает размер буфера исходного C-представления либо
отрицательный код `RAError*`. Для создания и выполнения определений Delphi-код
использует конструкторы `TRATrigger`, `TRAValue`, `TRALeaderboard` и
`TRARichPresence`. Модель размещения Delphi-объектов отличается от C-буфера.

`RA.Integration`, `RA.Integration.Windows` и `RA.ExternalClient` предоставляют
необязательные интерфейсы провайдеров и ABI-адаптеры. Приложение RetroMul работает
через нативный `TRASession`. Автоматический поиск и загрузка RA DLL исключены
по указанию пользователя; мост может принимать предоставленные вызывающим
кодом провайдеры и экспорты.

Проверки и C-эталоны находятся в `codex-work/ra-delphi`. C-эталоны и тестовые
DLL используются тестовыми программами и не включаются в приложение.
Исходная лицензия MIT сохранена в `LICENSE`.
