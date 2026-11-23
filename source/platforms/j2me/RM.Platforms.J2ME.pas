unit RM.Platforms.J2ME;

{$I RM.Mobile.inc}

interface

uses
  RM.Platform.Host, Core.EmulatorRegistry, RM.Input, RM.Input.Runtime, FMXInput;

type
  TJ2MEPlatform = class
  private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure LoadKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
  public
    class procedure RegisterPlatform; static;
  end;

function J2MEKeypadAction(Key: Integer): Integer;

implementation

uses
  System.SysUtils, System.UITypes, System.IniFiles, System.Math, Core.Platforms,
  Core.Emulation, Core.Archive.Container, Core.Archive.Zip,
  Core.PlatformServices, RM.Input.Gamepads, Core.Platforms.J2ME.Adapter,
  J2ME.Device, J2ME.Suite, J2ME.Metadata, RM.Platforms.Presentation,
  RM.Settings.Catalog, RM.Settings.Platform, RM.Settings.Builder,
  RM.Settings.Devices, RM.Settings.Callouts, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Session.Runtime, RM.Window.Layout,
  RM.Gamepad.Factory, RM.Platforms.J2ME.Gamepads, RM.Gamepad, J2ME.Input,
  RM.Dialogs, FMX.Types, FMX.Controls, FMX.Objects;

const
  PlatformIcon =
 'M41.0800018310547,7 L22.9200000762939,7 C22.2781753540039,7 21.6626396179199,7.25496387481689 21.2088012695313,7.70880174636841 C20.7549629211426,8.16263961791992 20.5,8.77817630767822 20.5,9.42000007629395 ' +
    'L20.5,21.5799999237061 C20.5,22.2218246459961 20.7549629211426,22.8373603820801 21.2088012695313,23.2911987304688 C21.6626396179199,23.7450370788574 22.2781753540039,24 22.9200000762939,24 L41.0800018310547,' +
    '24 C42.4165344238281,23.9999980926514 43.5,22.9165287017822 43.5,21.5799999237061 L43.5,9.42000007629395 C43.5,8.08347129821777 42.4165344238281,7.00000095367432 41.080005645752,7 Z M29,10 L25.8299999237061,' +
    '10 C25.1890926361084,9.9999942779541 24.574577331543,10.2552757263184 24.1223258972168,10.7094039916992 C23.6700744628906,11.1635313034058 23.4173412322998,11.7790966033936 23.4200000762939,12.4199991226196 ' +
    'L23.4200000762939,15 C23.4200000762939,15.3572654724121 23.2294006347656,15.6873931884766 22.9200000762939,15.8660259246826 C22.6105995178223,16.0446586608887 22.2294006347656,16.0446586608887 21.9200000762939,' +
    '15.8660249710083 C21.6105995178223,15.6873922348022 21.4200000762939,15.3572654724121 21.4200000762939,15 L21.4200000762939,12.4200000762939 C21.4200000762939,9.98278999328613 23.3928184509277,8.00550746917725 ' +
    '25.8300113677979,8 L29,8 C29.3572654724121,8 29.6873931884766,8.190598487854 29.8660259246826,8.5 C30.0446586608887,8.809401512146 30.0446586608887,9.190598487854 29.8660259246826,9.5 C29.6873931884766,' +
    '9.809401512146 29.3572654724121,10 29,10 Z M41,2 L23,2 C21.0108757019043,2 19.1032218933105,2.79017639160156 17.6966991424561,4.19669914245605 C16.2901763916016,5.60322237014771 15.5,7.51087713241577 15.5,' +
    '9.50000095367432 L15.5,54.5 C15.5,56.4891242980957 16.2901763916016,58.3967742919922 17.6966991424561,59.8032989501953 C19.1032218933105,61.2098197937012 21.0108757019043,62 23,62 L41,62 C42.9891242980957,' +
    '62 44.8967742919922,61.2098236083984 46.3032989501953,59.8032989501953 C47.7098236083984,58.3967742919922 48.5,56.4891242980957 48.5,54.5 L48.5,9.5 C48.5,7.51087617874146 47.7098236083984,5.60322189331055 ' +
    '46.3032989501953,4.19669914245605 C44.8967742919922,2.79017615318298 42.9891242980957,1.99999988079071 41,2 Z M19,38 C19,37.7347831726074 19.1053562164307,37.4804306030273 19.2928924560547,37.2928924560547 ' +
    'C19.4804286956787,37.105354309082 19.7347831726074,37 20,37 L24,37 C24.3572654724121,37 24.6873931884766,37.1905975341797 24.8660259246826,37.5 C25.0446586608887,37.8094024658203 25.0446586608887,38.1905975341797 ' +
    '24.8660259246826,38.5 C24.6873931884766,38.8094024658203 24.3572654724121,39 24,39 L20,39 C19.7347831726074,39 19.4804286956787,38.894645690918 19.2928924560547,38.7071075439453 C19.1053562164307,38.5195693969727 ' +
    '19,38.2652168273926 19,38 Z M19,30 C19,29.7347831726074 19.1053562164307,29.4804286956787 19.2928924560547,29.2928924560547 C19.4804286956787,29.1053562164307 19.7347831726074,29 20,29 L24,29 C24.3572654724121,' +
    '29 24.6873931884766,29.1905994415283 24.8660259246826,29.5 C25.0446586608887,29.8094005584717 25.0446586608887,30.1905994415283 24.8660259246826,30.5 C24.6873931884766,30.8094005584717 24.3572654724121,' +
    '31 24,31 L20,31 C19.7347831726074,31 19.4804286956787,30.8946437835693 19.2928924560547,30.7071075439453 C19.1053562164307,30.5195713043213 19,30.2652168273926 19,30 Z M25,57 L21,57 C20.6427345275879,57 ' +
    '20.3126068115234,56.8094024658203 20.1339740753174,56.5 C19.9553413391113,56.1905975341797 19.9553413391113,55.8094024658203 20.1339740753174,55.5 C20.3126068115234,55.1905975341797 20.6427345275879,55 ' +
    '21,55 L25,55 C25.3572654724121,55 25.6873931884766,55.1905975341797 25.8660259246826,55.5 C26.0446586608887,55.8094024658203 26.0446586608887,56.1905975341797 25.8660259246826,56.5 C25.6873931884766,56.8094024658203 ' +
    '25.3572654724121,57 25,57 Z M25,51 L21,51 C20.6427345275879,51 20.3126068115234,50.8094024658203 20.1339740753174,50.5 C19.9553413391113,50.1905975341797 19.9553413391113,49.8094024658203 20.1339740753174,' +
    '49.5 C20.3126068115234,49.1905975341797 20.6427345275879,49 21,49 L25,49 C25.3572654724121,49 25.6873931884766,49.1905975341797 25.8660259246826,49.5 C26.0446586608887,49.8094024658203 26.0446586608887,' +
    '50.1905975341797 25.8660259246826,50.5 C25.6873931884766,50.8094024658203 25.3572654724121,51 25,51 Z M25,45 L21,45 C20.6427345275879,45 20.3126068115234,44.8094024658203 20.1339740753174,44.5 C19.9553413391113,' +
    '44.1905975341797 19.9553413391113,43.8094024658203 20.1339740753174,43.5 C20.3126068115234,43.1905975341797 20.6427345275879,43 21,43 L25,43 C25.3572654724121,43 25.6873931884766,43.1905975341797 25.8660259246826,' +
    '43.5 C26.0446586608887,43.8094024658203 26.0446586608887,44.1905975341797 25.8660259246826,44.5 C25.6873931884766,44.8094024658203 25.3572654724121,45 25,45 Z M34,57 L30,57 C29.6427345275879,57 29.3126068115234,' +
    '56.8094024658203 29.1339740753174,56.5 C28.9553413391113,56.1905975341797 28.9553413391113,55.8094024658203 29.1339740753174,55.5 C29.3126068115234,55.1905975341797 29.6427345275879,55 30,55 L34,55 C34.3572654724121,' +
    '55 34.6873893737793,55.1905975341797 34.866024017334,55.5 C35.0446586608887,55.8094024658203 35.0446586608887,56.1905975341797 34.866024017334,56.5 C34.6873893737793,56.8094024658203 34.3572654724121,57 ' +
    '34,57 Z M34,51 L30,51 C29.6427345275879,51 29.3126068115234,50.8094024658203 29.1339740753174,50.5 C28.9553413391113,50.1905975341797 28.9553413391113,49.8094024658203 29.1339740753174,49.5 C29.3126068115234,' +
    '49.1905975341797 29.6427345275879,49 30,49 L34,49 C34.3572654724121,49 34.6873893737793,49.1905975341797 34.866024017334,49.5 C35.0446586608887,49.8094024658203 35.0446586608887,50.1905975341797 34.866024017334,' +
    '50.5 C34.6873893737793,50.8094024658203 34.3572654724121,51 34,51 Z M34,45 L30,45 C29.6427345275879,45 29.3126068115234,44.8094024658203 29.1339740753174,44.5 C28.9553413391113,44.1905975341797 28.9553413391113,' +
    '43.8094024658203 29.1339740753174,43.5 C29.3126068115234,43.1905975341797 29.6427345275879,43 30,43 L34,43 C34.3572654724121,43 34.6873893737793,43.1905975341797 34.866024017334,43.5 C35.0446586608887,' +
    '43.8094024658203 35.0446586608887,44.1905975341797 34.866024017334,44.5 C34.6873893737793,44.8094024658203 34.3572654724121,45 34,45 Z M32,40 C29.5732269287109,40 27.3854084014893,38.5381469726563 26.4567222595215,' +
    '36.2961006164551 C25.5280361175537,34.0540542602539 26.0413722991943,31.4733467102051 27.757360458374,29.7573585510254 C29.4733486175537,28.0413703918457 32.0540542602539,27.5280361175537 34.2961006164551,' +
    '28.4567222595215 C36.5381469726563,29.3854084014893 38,31.5732269287109 38,34 C38,35.5912971496582 37.3678588867188,37.1174240112305 36.2426414489746,38.2426414489746 C35.1174240112305,39.3678588867188 ' +
    '33.5912971496582,40 32,40 Z M43,57 L39,57 C38.6427345275879,57 38.3126106262207,56.8094024658203 38.133975982666,56.5 C37.9553413391113,56.1905975341797 37.9553413391113,55.8094024658203 38.133975982666,' +
    '55.5 C38.3126106262207,55.1905975341797 38.6427345275879,55 39,55 L43,55 C43.3572654724121,55 43.6873893737793,55.1905975341797 43.866024017334,55.5 C44.0446586608887,55.8094024658203 44.0446586608887,' +
    '56.1905975341797 43.866024017334,56.5 C43.6873893737793,56.8094024658203 43.3572654724121,57 43,57 Z M43,51 L39,51 C38.6427345275879,51 38.3126106262207,50.8094024658203 38.133975982666,50.5 C37.9553413391113,' +
    '50.1905975341797 37.9553413391113,49.8094024658203 38.133975982666,49.5 C38.3126106262207,49.1905975341797 38.6427345275879,49 39,49 L43,49 C43.3572654724121,49 43.6873893737793,49.1905975341797 43.866024017334,' +
    '49.5 C44.0446586608887,49.8094024658203 44.0446586608887,50.1905975341797 43.866024017334,50.5 C43.6873893737793,50.8094024658203 43.3572654724121,51 43,51 Z M43,45 L39,45 C38.6427345275879,45 38.3126106262207,' +
    '44.8094024658203 38.133975982666,44.5 C37.9553413391113,44.1905975341797 37.9553413391113,43.8094024658203 38.133975982666,43.5 C38.3126106262207,43.1905975341797 38.6427345275879,43 39,43 L43,43 C43.3572654724121,' +
    '43 43.6873893737793,43.1905975341797 43.866024017334,43.5 C44.0446586608887,43.8094024658203 44.0446586608887,44.1905975341797 43.866024017334,44.5 C43.6873893737793,44.8094024658203 43.3572654724121,45 ' +
    '43,45 Z M44,39 L40,39 C39.6427345275879,39 39.3126106262207,38.8094024658203 39.133975982666,38.5 C38.9553413391113,38.1905975341797 38.9553413391113,37.8094024658203 39.133975982666,37.5 C39.3126106262207,' +
    '37.1905975341797 39.6427345275879,37 40,37 L44,37 C44.3572654724121,37 44.6873893737793,37.1905975341797 44.866024017334,37.5 C45.0446586608887,37.8094024658203 45.0446586608887,38.1905975341797 44.866024017334,' +
    '38.5 C44.6873893737793,38.8094024658203 44.3572654724121,39 44,39 Z M44,31 L40,31 C39.6427345275879,31 39.3126106262207,30.8094005584717 39.133975982666,30.5 C38.9553413391113,30.1905994415283 38.9553413391113,' +
    '29.8094005584717 39.133975982666,29.5 C39.3126106262207,29.1905994415283 39.6427345275879,29 40,29 L44,29 C44.3572654724121,29 44.6873893737793,29.1905994415283 44.866024017334,29.5 C45.0446586608887,29.8094005584717 ' +
    '45.0446586608887,30.1905994415283 44.866024017334,30.5 C44.6873893737793,30.8094005584717 44.3572654724121,31 44,31 Z M45.5,21.5799999237061 C45.5,24.0210971832275 43.5210990905762,26 41.0800018310547,' +
    '26 L22.9200000762939,26 C21.7477436065674,26 20.623498916626,25.5343227386475 19.7945880889893,24.7054119110107 C18.9656772613525,23.876501083374 18.5,22.7522563934326 18.5,21.5799999237061 L18.5,9.42000007629395 ' +
    'C18.5,8.24774265289307 18.9656772613525,7.12349843978882 19.7945880889893,6.2945876121521 C20.623498916626,5.46567726135254 21.7477436065674,5 22.9200000762939,5 L41.0800018310547,5 C43.5211029052734,5.00000095367432 ' +
    '45.5,6.97890329360962 45.5,9.42000102996826 Z M36,34 C36,35.617847442627 35.0254325866699,37.0763931274414 33.5307350158691,37.6955184936523 C32.0360374450684,38.3146438598633 30.3155651092529,37.9724197387695 ' +
    '29.171573638916,36.828426361084 C28.0275821685791,35.6844329833984 27.6853580474854,33.9639625549316 28.3044815063477,32.4692649841309 C28.92360496521,30.9745674133301 30.3821506500244,30 32,30 C33.0608673095703,' +
    '30 34.0782814025879,30.4214286804199 34.828426361084,31.171573638916 C35.5785713195801,31.9217185974121 36,32.9391326904297 36,34 Z ';

type
  TJ2MEInputHandler = class(TPlatformInputHandler)
  public
    class function KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy; override;
    class function ForwardKey(const Context: TInputRuntimeContext; Code: Word; Pressed: Boolean): Boolean; override;
    class procedure CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput); override;
  end;

  TJ2MESettings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
    procedure PrepareSave(Draft: TMemIniFile); override;
  end;

  TJ2MESettingsDevices = class(TPlatformSettingsDevices)
  public
    class function Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>; override;
    class function Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding; override;
  end;

  TJ2MEDeviceCallouts = class(TPlatformDeviceCallouts)
  public
    class function Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>; override;
  end;

  IJ2MEKeypadOptions = interface
    ['{2603032D-5F9D-40B0-A992-0DDBB8D5B20B}']
    function IsShown: Boolean;
  end;

  TJ2MEKeypadOptions = class(TInterfacedObject, IJ2MEKeypadOptions)
  public
    Shown: Boolean;
    function IsShown: Boolean;
  end;

  TJ2MESessionHandler = class(TPlatformSessionHandler)
  public
    class procedure Connect(const Context: TSessionRuntimeContext); override;
    class procedure Disconnect(const Context: TSessionRuntimeContext); override;
    class procedure SyncActivity(const Context: TSessionRuntimeContext); override;
    class procedure FramePresented(const Context: TSessionRuntimeContext); override;
  end;

  TJ2MESettingsHandler = class(TPlatformSettingsHandler)
  public
    class procedure Apply(const Context: TSettingsRuntimeContext; Ini: TCustomIniFile); override;
  end;

  TJ2MEWindowLayout = class(TPlatformWindowLayout)
  public
    class procedure Arrange(const Context: TWindowLayoutContext); override;
  end;

  TJ2MEControlsHelp = class(TPlatformControlsHelp)
  public
    class function Info(const Context: TControlsHelpContext): TControlsHelpInfo; override;
    class function Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>; override;
    class function StandardShortcutAvailable(const Context: TControlsHelpContext; const Id: string): Boolean; override;
  end;

const
  J2MEKeypadActionBase = 2560;

function J2MEKeypadAction(Key: Integer): Integer;
begin
  // Keep the existing, assignable 0 action and its saved bindings.
  if Key = 0 then
    Result := PadAction(0, TEmulatorButton.B)
  else
    Result := J2MEKeypadActionBase + Key;
end;

function IsJ2MEKeypadAction(Action: Integer): Boolean;
begin
  Result := (Action > J2MEKeypadActionBase) and (Action <= J2MEKeypadActionBase + 11);
end;

procedure LoadJ2MEKeypadBindings(Input: TInputManager; Ini: TCustomIniFile);
begin
  for var Key := 1 to 9 do
  begin
    AddLegacyInputKey(Input, J2MEKeypadAction(Key), vk0 + Key);
    AddLegacyInputKey(Input, J2MEKeypadAction(Key), vkNumpad0 + Key);
  end;
  AddLegacyInputKey(Input, J2MEKeypadAction(10), vkF3);
  AddLegacyInputKey(Input, J2MEKeypadAction(10), vkMultiply);
  AddLegacyInputKey(Input, J2MEKeypadAction(11), vkF4);
  AddLegacyInputKey(Input, J2MEKeypadAction(11), vkDivide);
end;

procedure LoadJ2MELegacyBindings(Input: TInputManager; Ini: TCustomIniFile);
begin
  LoadJ2MEKeypadBindings(Input, Ini);
  AddLegacyInputKey(Input, J2MEKeypadAction(0), vkNumpad0);
  AddLegacyInputKey(Input, PadAction(0, TEmulatorButton.A), vkSpace);
end;

procedure MigrateJ2MEKeypadBindings(Input: TInputManager; Ini: TCustomIniFile);
begin
  if Ini.ReadInteger('FMXInput', 'J2MEKeypadVersion', 0) >= 1 then
    Exit;
  var HasKeypad := False;
  for var Binding in Input.Bindings do
    HasKeypad := HasKeypad or IsJ2MEKeypadAction(Binding.Action);
  // Older profiles received digits outside the binding manager. Mark the
  // draft immediately so switching pages cannot restore cleared assignments.
  if not HasKeypad and (Ini.ReadString('FMXInput', 'Bindings', '') <> '') then
    LoadJ2MEKeypadBindings(Input, Ini);
  Ini.WriteInteger('FMXInput', 'J2MEKeypadVersion', 1);
end;

procedure FilterJ2MEKeypadBinding(const Binding: TInputBinding; Ini: TCustomIniFile; var Policy: TInputBindingPolicy);
begin
  if not IsJ2MEKeypadAction(Binding.Action) then
    Exit;
  Policy.SourceKey := 'Source1';
  Policy.Enabled := not SameText(Ini.ReadString('Ports', 'Port1', 'auto'), 'none');
end;

function TJ2MEKeypadOptions.IsShown: Boolean;
begin
  Result := Shown;
end;

class procedure TJ2MEWindowLayout.Arrange(const Context: TWindowLayoutContext);
begin
  var Pad := Context.Gamepad;
  if (Pad = nil) or not Pad.Visible or (Pad.PlatformPad = nil) or not (Pad.Parent is TControl) then
  begin
    inherited;
    Exit;
  end;
  var Host := TControl(Pad.Parent);
  // A complete phone panel uses a separate area. Split controls overlay only
  // the sides; they keep the central game picture available in landscape.
  if Pad.PlatformPad.DesignWidth = Pad.PlatformPad.DesignSideSize.Width then
  begin
    Context.Host.Video.FitFrame;
    if Host.Width > Host.Height then
    begin
      Pad.Align := TAlignLayout.Right;
      Pad.Width := Min(280.0, Host.Width * 0.4);
    end
    else
    begin
      Pad.Align := TAlignLayout.Bottom;
      Pad.Height := TScreenGamepad.PreferredHeight(Host.Width, Host.Height);
    end;
    Pad.BringToFront;
  end
  else
    inherited;
end;

procedure ConfigureJ2MEKeypad(const Context: TInputRuntimeContext; Ini: TCustomIniFile);
begin
  var Options := TJ2MEKeypadOptions.Create;
  Options.Shown := Ini.ReadBool('Phone', 'ShowKeypad', True);
  Context.SetData('j2me.keypad.options', Options);
  var Pad := Context.Gamepad;
  if Pad = nil then
    Exit;
  var Layout := NormalizeJ2MEKeypadLayout(Ini.ReadString('Phone', 'KeypadLayout', 'arrows-numbers'));
  Pad.Configure('j2me', Layout, CoreButtons('j2me', 'auto'));
  Pad.PlatformPad.InkOpacity := EnsureRange(Ini.ReadInteger('Phone', 'KeypadOpacity', 85), 10, 100) / 100;
end;

class procedure TJ2MESessionHandler.Connect(const Context: TSessionRuntimeContext);
begin
  inherited;
  var Ini := Context.Host.Storage.ReadConfig(Context.Host.Core.Config.FileName);
  try
    ConfigureJ2MEKeypad(Context, Ini);
  finally
    Ini.Free;
  end;
end;

class procedure TJ2MESessionHandler.FramePresented(const Context: TSessionRuntimeContext);
begin
  inherited;
  if not Context.Host.Activity.CanShowGameNotice then
    Exit;
  var Advice: IJ2MEResolutionAdvice;
  var Current, Recommended: TJ2MEScreenSize;
  if Supports(Context.Host.Core, IJ2MEResolutionAdvice, Advice) and
    Advice.TakeResolutionAdvice(Current, Recommended) then
    Context.Host.ShowMessage(
      Format(Translate('The game repeatedly requests a %d × %d screen. The current size is %d × %d, so part of the image may be clipped.'),
        [Recommended.Width, Recommended.Height, Current.Width, Current.Height]) + sLineBreak + sLineBreak +
      Translate('Set this size in the Java ME platform video settings, then restart the game from the beginning.'),
      False);
end;

class procedure TJ2MESessionHandler.SyncActivity(const Context: TSessionRuntimeContext);
begin
  inherited;
  var Pad := Context.Gamepad;
  if Pad = nil then
    Exit;
  var Options := Context.Data('j2me.keypad.options') as IJ2MEKeypadOptions;
  var Activity := Context.Host.Activity;
  Pad.Visible := Pad.Visible and ((Options = nil) or Options.IsShown);
  Pad.Enabled := Pad.Enabled and Pad.Visible and Activity.VirtualControlsEnabled and
    not Activity.PeripheralInputBlocked;
  LayoutControls(Context);
end;

class procedure TJ2MESessionHandler.Disconnect(const Context: TSessionRuntimeContext);
begin
  if Context.Gamepad <> nil then
  begin
    Context.Gamepad.ReleaseAll;
    Context.Gamepad.Enabled := False;
    Context.Gamepad.Visible := False;
  end;
  var Phone: IJ2MEPhoneInput;
  if Supports(Context.Host.Core, IJ2MEPhoneInput, Phone) then
    Phone.SetVirtualKeypad(0);
  Context.SetData('j2me.keypad.options', nil);
  inherited;
end;

class procedure TJ2MESettingsHandler.Apply(const Context: TSettingsRuntimeContext; Ini: TCustomIniFile);
begin
  inherited;
  ConfigureJ2MEKeypad(Context, Ini);
end;

class procedure TJ2MEInputHandler.CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput);
begin
  var Phone: IJ2MEPhoneInput;
  if not Supports(Context.Host.Core, IJ2MEPhoneInput, Phone) then
    Exit;
  var Mask: Word := 0;
  var Pad := Context.Gamepad;
  if (Context.Host.Input.Ports.Devices[0] <> 'none') and
    not (Context.Host.Activity.Phase = TPlatformSessionPhase.Failed) and not Context.Host.Core.IsPaused then
  begin
    var Manager := Context.Host.Input;
    if Manager.HasInputSource then
      for var Key := 0 to 11 do
        if Manager.IsActionPressed(J2MEKeypadAction(Key)) then
          Mask := Mask or (Word(1) shl Key);
    if (Pad <> nil) and Pad.Visible and Pad.Enabled then
      Mask := Mask or (Pad.AuxiliaryButtons and J2MEKeypadMask);
  end;
  Phone.SetVirtualKeypad(Mask);
end;

class function TJ2MEInputHandler.ForwardKey(const Context: TInputRuntimeContext; Code: Word; Pressed: Boolean): Boolean;
begin
  Result := False;
  var Manager := Context.Host.Input;
  if not Manager.HasInputSource then
    Exit;
  // Binding changes replace default keys rather than add a hard-coded route.
  // Other text/navigation keys still reach the MIDlet.
  if Code in [vk0..vk9, vkNumpad0..vkNumpad9, vkUp, vkDown, vkLeft, vkRight,
      vkReturn, vkSpace, vkF1..vkF4, vkMultiply, vkDivide] then
    Exit(True);
  var Hid := HostKeyToHid(Code);
  for var Binding in Manager.Bindings do
    if (Binding.Kind = TInputElementKind.Key) and (Binding.Code = Hid) and
      ((Binding.Action in [0..7]) or IsJ2MEKeypadAction(Binding.Action)) then
      Exit(True);
end;

class function TJ2MEControlsHelp.Info(const Context: TControlsHelpContext): TControlsHelpInfo;
begin
  Result := inherited;
  Result.ControllerTitle := Translate('Phone keypad');
  Result.Note := Translate('L/R: soft keys. OK: Fire. Digits, * and # keep their phone key codes; arrows are separate keys.') + ' ' +
    Translate('Change bindings in the controls settings.');
end;

class function TJ2MEControlsHelp.Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>;
begin
  Result := inherited;
  if (Context.Player <> 0) or (Length(Result) = 0) then
    Exit;
  for var Key := 1 to 11 do
    Result := Result + [TControlsHelpAssignment.Create(Char(J2MEKeypadCodes[Key]), J2MEKeypadAction(Key))];
end;

class function TJ2MESettingsDevices.Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>;
begin
  Result := inherited;
  if (Context.Port <> 0) or (Length(Result) = 0) then
    Exit;
  for var Key := 1 to 11 do
    Result := Result + [TSettingsDeviceBinding.Create(J2MEKeypadAction(Key), Char(J2MEKeypadCodes[Key]))];
end;

class function TJ2MESettingsDevices.Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding;
begin
  Result := inherited;
  if (Context.Port <> 0) or not (Control is TScreenGamepad) then
    Exit;
  for var Key := 0 to 11 do
    if (TScreenGamepad(Control).AuxiliaryButtons and (Cardinal(1) shl Key)) <> 0 then
      Exit(TSettingsDeviceBinding.Create(J2MEKeypadAction(Key), Char(J2MEKeypadCodes[Key])));
end;

class function TJ2MEDeviceCallouts.Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>;
begin
  Result := inherited;
  if (Context.Port <> 0) or not (Context.Device is TScreenGamepad) then
    Exit;
  for var Key := 0 to 11 do
    if not ButtonBounds(Context, -1 - Key).IsEmpty then
      Result := Result + [TDeviceCalloutDefinition.Create(-1 - Key, J2MEKeypadAction(Key),
        Char(J2MEKeypadCodes[Key]), Char(J2MEKeypadCodes[Key]), False)];
  for var I := 0 to High(Result) do
    Result[I].Left := ButtonBounds(Context, Result[I].Button).CenterPoint.X < Context.Device.Width / 2;
end;

procedure TJ2MESettings.PrepareSave(Draft: TMemIniFile);
begin
  inherited;
  Draft.WriteInteger('FMXInput', 'J2MEKeypadVersion', 1);
end;

class function TJ2MEControlsHelp.StandardShortcutAvailable(const Context: TControlsHelpContext; const Id: string): Boolean;
begin
  Result := inherited;
  if Id = 'pause' then
    Result := False;
end;

procedure TJ2MESettings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupJ2MEKeypad', 'Phone keypad');
  Context.AddBoolean('RowJ2MEShowKeypad', 'On-screen phone keypad',
    'Show phone buttons during emulation. Supports mouse and simultaneous touches.', 'Phone', 'ShowKeypad', True);
  Context.AddChoice('RowJ2MEKeypadLayout', 'Keypad layout',
    'Choose phone keys, arrows or both. The split layouts keep the centre clear.',
    'Phone', 'KeypadLayout', [
      SettingChoice('Arrows and numbers', 'arrows-numbers'),
      SettingChoice('Numbers and arrows', 'numbers-arrows'),
      SettingChoice('Phone', 'phone'),
      SettingChoice('Phone with arrows', 'phone-arrows'),
      SettingChoice('Numbers', 'numbers'),
      SettingChoice('Arrows', 'arrows')], 'arrows-numbers');
  var Opacity := Context.AddInteger('RowJ2MEKeypadOpacity', 'Keypad opacity (%)',
    'Button size and bottom offset use the general on-screen button settings.',
    'Phone', 'KeypadOpacity', 85, 100);
  Opacity.Min := 10;
end;

class function TJ2MEInputHandler.KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy;
begin
  Result := inherited;
  Result.KeyboardActive := True;
  Result.ForwardWithManager := True;
  Result.ReserveCaptureShortcuts := True;
  Result.ControlKeys := [vkF7, vkF8, vkF9, vkF10];
end;

procedure TJ2MESettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupJ2MEPhone', 'Java ME phone');
  var Sizes: TArray<TSettingsChoiceItem> := [SettingChoice('Automatic', 'auto'), SettingChoice('Custom width and height', 'custom')];
  for var Size in TJ2MEScreenSize.Presets do
    Sizes := Sizes + [SettingChoice(IntToStr(Size.Width) + ' × ' + IntToStr(Size.Height), Size.ToString)];
  var DefaultSize := 'auto';
  if (Context.Draft <> nil) and not Context.Draft.ValueExists('Phone', 'ScreenSize') and
    (Context.Draft.ValueExists('Phone', 'Width') or
    Context.Draft.ValueExists('Phone', 'Height')) then
    DefaultSize := 'custom';
  var Preset := Context.AddChoice('RowJ2MEScreenSize', 'Virtual Canvas size', 'Automatic selects a compatible Canvas and applies JAR/JAD scaling. Manual sizes take priority. Reopen the game to apply.', 'Phone', 'ScreenSize', Sizes, DefaultSize);
  Preset.ApplyMode := TSettingsApplyMode.OnNextLoad;
  var W := Context.AddInteger('RowJ2MEWidth', 'Screen width', 'Reopen the game to apply.', 'Phone', 'Width', 240, 1024);
  W.Min := 1;
  W.ApplyMode := TSettingsApplyMode.OnNextLoad;
  W.EnabledWhen :=
    function: Boolean
    begin
      Result := Preset.Value = 'custom';
    end;
  var H := Context.AddInteger('RowJ2MEHeight', 'Screen height', 'Reopen the game to apply.', 'Phone', 'Height', 320, 1024);
  H.Min := 1;
  H.ApplyMode := TSettingsApplyMode.OnNextLoad;
  H.EnabledWhen :=
    function: Boolean
    begin
      Result := Preset.Value = 'custom';
    end;
  Context.AddBoolean('RowJ2MEResolutionRecommendations', 'Show resolution recommendations',
    'Suggest a screen size detected during emulation. Shown only when starting a game from the beginning.',
    'Phone', 'ShowResolutionRecommendations', True);
  var M := Context.AddInteger('RowJ2MEMIDlet', 'MIDlet index', 'Zero selects the first application in the suite.', 'Phone', 'MIDletIndex', 0, 1023);
  M.Min := 0;
  M.ApplyMode := TSettingsApplyMode.OnNextLoad;
end;

class function TJ2MEPlatform.Recognize(Context: TCoreLoadContext): TCoreMatch;
var
  Archive: Core.Archive.Container.IArchiveContainer;
begin
  Result := nil;
  // JAR is a complete MIDlet suite, not a generic ROM archive to unpack.
  // PrepareArchive intentionally opens only ZIP/7z/RAR source extensions.
  if not Context.HasExtension(['.jar']) then
    Exit;
  Archive := Context.Archive;
  if Archive = nil then
  begin
    var Saved := Context.Stream.Position;
    try
      Context.Stream.Position := 0;
      if not IsZipArchive(Context.Stream) then
        Exit;
      Archive := OpenZip(Context.Stream, Context.EffectiveStorage);
    finally
      Context.Stream.Position := Saved;
    end;
  end;
  if Archive = nil then
    Exit;
  var HasManifest := False;
  for var I := 0 to Archive.Count - 1 do
  begin
    var Entry := Archive.Entries[I];
    if not Entry.IsDirectory and SameText(Entry.Name, J2MEManifestName) then
    begin
      HasManifest := True;
      Break;
    end;
  end;
  if not HasManifest then
  begin
    var Location, Error: string;
    var JAD := ReadJ2MEJAD(Context.Stream, Context.EffectiveStorage, Context.RomName, Location, Error);
    if Length(JAD) = 0 then
      Exit;
    // The archive has no manifest. Verify the companion before claiming J2ME.
    TJ2MESuite.Create(Archive, JAD, Context.EffectiveStorage, Context.Stream.Size).Free;
  end;
  Result := TCoreMatch.Create('J2ME',
    function: IEmulationCore
    begin
      Context.Stream.Position := 0;
      Result := TJ2MECoreAdapter.Create(Context.Stream, Context.EffectiveStorage, Context.RomName);
    end);
  Result.Format.SystemId := 'j2me';
end;

class procedure TJ2MEPlatform.LoadKeys(var Keys: TPlatformInputKeyMap);
begin
  Keys[0, TEmulatorButton.Up] := vkUp;
  Keys[0, TEmulatorButton.Down] := vkDown;
  Keys[0, TEmulatorButton.Left] := vkLeft;
  Keys[0, TEmulatorButton.Right] := vkRight;
  Keys[0, TEmulatorButton.A] := vkReturn;
  Keys[0, TEmulatorButton.B] := Ord('0');
  Keys[0, TEmulatorButton.Select] := vkF1;
  Keys[0, TEmulatorButton.Start] := vkF2;
end;

class procedure TJ2MEPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
end;

class procedure TJ2MEPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  TPlatformRegistry.RegisterPlatform('j2me', 'Java ME', 'J2ME', 'Java',
    'CLDC MIDP mobile phone Java games', 'j2me', ['j2me', 'javame', 'midp'], ['.jar'], 'J2ME', 'j2me', 1);
  var Registration := TEmulationCoreRegistration.Create('J2ME', ['.jar']);
  Registration.Add(TCoreLoadStage.Source, 50, Recognize);
  RegisterEmulationCore(Registration);
  var Services := Default(TPlatformServices);
  Services.TerminalInput :=
    function(const Core: IEmulationCore): TTerminalInputPolicy
    begin
      Result := Default(TTerminalInputPolicy);
      Result.AllKeys := True;
      Result.ExitKey := vkEscape;
    end;
  RegisterPlatformServices('j2me', Services);
  RegisterSettingsPlatform('j2me', TJ2MESettings,
    'Open the application JAR. Keep its matching JAD beside it when available. Start with ' +
    'automatic virtual Canvas size and choose a phone keypad layout if the game expects ' +
    'different keys. Some MIDlets require phone-specific features.');
  RegisterPlatformSettingsDevices('j2me', TJ2MESettingsDevices);
  RegisterPlatformDeviceCallouts('j2me', TJ2MEDeviceCallouts);
  RegisterPlatformControlsHelp('j2me', TJ2MEControlsHelp);
  RegisterPlatformSettingsHandler('j2me', TJ2MESettingsHandler);
  RegisterPlatformWindowLayout('j2me', TJ2MEWindowLayout);
  RegisterPlatformSessionHandler('j2me', TJ2MESessionHandler);
  RegisterPlatformInputHandler('j2me', TJ2MEInputHandler);
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down,
      TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
      TEmulatorButton.Select, TEmulatorButton.Start]);
  Definition.ButtonNames[TEmulatorButton.A] := 'Fire';
  Definition.ButtonNames[TEmulatorButton.B] := '0';
  Definition.ButtonNames[TEmulatorButton.Select] := 'Left soft key';
  Definition.ButtonNames[TEmulatorButton.Start] := 'Right soft key';
  Definition.LegacyPorts := 1;
  Definition.LegacySection := 'Keys';
  Definition.LoadLegacyKeys := LoadKeys;
  Definition.AfterLegacyBindings := LoadJ2MELegacyBindings;
  Definition.AfterLoadBindings := MigrateJ2MEKeypadBindings;
  Definition.FilterBinding := FilterJ2MEKeypadBinding;
  Definition.UseSharedBindingRules := True;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('j2me', Definition);
  RegisterPlatformGamepads('j2me', TGamepadJ2MEArrowsNumbers, [
      TGamepadDeviceVariant.Create('numbers-arrows', TGamepadJ2ME),
      TGamepadDeviceVariant.Create('arrows-numbers', TGamepadJ2MEArrowsNumbers),
      TGamepadDeviceVariant.Create('phone', TGamepadJ2MEPhone),
      TGamepadDeviceVariant.Create('phone-arrows', TGamepadJ2MEPhoneArrows),
      TGamepadDeviceVariant.Create('numbers', TGamepadJ2MENumbers),
      TGamepadDeviceVariant.Create('arrows', TGamepadJ2MEArrows)]);
  RegisterPlatformPresentation('j2me', 'j2me', PlatformIcon);
  FRegistered := True;
end;

end.

