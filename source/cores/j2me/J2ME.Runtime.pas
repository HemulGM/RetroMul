unit J2ME.Runtime;

interface

uses
  System.Classes, JVM.StateIO, System.Math, System.SysUtils,
  System.Generics.Collections, JVM.Types, JVM.ClassFile, JVM.Runtime,
  Core.Emulation.Types, Java.Bootstrap, J2ME.Device, J2ME.Input, J2ME.Suite,
  J2ME.Media, J2ME.Media.Video, J2ME.RMS, J2ME.LCDUI, J2ME.Network,
  J2ME.FileSystem, Core.Bluetooth.Types, Core.Messaging.Types, J2ME.Messaging,
  J2ME.Bluetooth, J2ME.Nokia.UI, J2ME.Nokia.Sound, J2ME.Effects,
  J2ME.Siemens.Game, J2ME.Sensor;

{$SCOPEDENUMS ON}

type
  TJ2MEState = (Created, Starting, Active, Paused, Destroyed, Faulted);

  TJ2MEDisplayChange = record
    Previous, Current: Integer;
  end;

  TJ2MEInvocation = record
    ClassName, Name, Descriptor: string;
    Arguments: TArray<TJVMValue>;
  end;

  TJ2MECustomKeyRepeat = record
    Code, Item: Integer;
    Next: Int64;
  end;

  TJ2MEHost = class(TJavaHost)
  private
    FSuite: TJ2MESuite;
    FDefaultEncoding: string;
    FStackAttack2, FSummerSki, FMarslander: Boolean;
    FArmiesOfWarClass: TJVMClass;
    FExplicitInitialPaintClass: string;
    FEmptyGameURLTemplate, FSamsungVibrationMillis: Boolean;
    FKeyLayout: TJ2MEKeyLayout;
    FNativePixelFormat: Integer;
    FWallOffset, FMonotonicOffset: Int64;
    FExecutionPaused, FLifecyclePaused: Boolean;
    FExecutionWall, FExecutionMono: Int64;
    FVM: TJVM;
    FDisplay, FScreen: Integer;
    FWidth, FHeight: Integer;
    FViewportEvidence: TJ2MEViewportEvidence;
    FViewportScreen: Integer;
    FPixels, FContentPixels: TArray<UInt32>;
    FRepaint, FNotifyDestroyed, FNotifyPaused, FHasContent: Boolean;
    FRootMIDlet: Integer;
    FMIDletStarted, FGuestPaused, FResumeRequested: Boolean;
    FLifecycleError: string;
    FPhysicalKeys: TDictionary<Integer, Boolean>;
    FKnownPhysicalKeys: TDictionary<Integer, Boolean>;
    FCustomKeyRepeats: TList<TJ2MECustomKeyRepeat>;
    FDisplayChanges: TQueue<TJ2MEDisplayChange>;
    FFlushCount: UInt64;
    FMedia: TJ2MEMedia;
    FRMS: TJ2MERMS;
    FNetwork: TJ2MENetwork;
    FSensors: TJ2MESensors;
    FFileSystem: TJ2MEFileSystem;
    FBluetooth: IBluetoothProvider;
    FMessagingProvider: IMessagingProvider;
    FMessaging: TJ2MEMessaging;
    FBluetoothAPI: TJ2MEBluetooth;
    FUI: TJ2MELCDUI;
    FEffects: TJ2MEDeviceEffects;
    FSiemens: TJ2MESiemensGame;
    FNokiaUI: TJ2MENokiaUI;
    FNokiaSound: TJ2MENokiaSound;
    FUIJobs: TQueue<TJ2MEInvocation>;
    FLayoutHeight: Integer;
    FPlatformName, FLocale: string;
    function HasDisplayForeground(IgnoreExecutionPause: Boolean = False): Boolean;
    function IsDisplayShown(Screen: Integer): Boolean;
    procedure HideCurrentCanvas;
    function DisplayGraphics(Screen: Integer): Integer;
    procedure QueueUI(const ClassName, Name, Descriptor: string; const Args: array of TJVMValue);
    function WaitingForInitialPaint(Canvas: TJVMObject): Boolean;
    function AutomaticPaintReady: Boolean;
    procedure ChangeScreen(Screen: Integer);
    procedure PostAlertTimeout(Screen, Generation: Integer);
    function CustomKeyRepeatIndex(Code: Integer): Integer;
  public
    constructor Create(Suite: TJ2MESuite; Width, Height: Integer; const Bluetooth: IBluetoothProvider; const Messaging: IMessagingProvider);
    destructor Destroy; override;
    procedure Install(VM: TJVM);
    procedure PrepareClass(C: TJVMClass); override;
    function LoadClass(const Name: string): TBytes; override;
    function LoadResource(const Name: string; out Data: TBytes): Boolean; override;
    function LoadClassResource(const ClassName, Name: string; out Data: TBytes): Boolean; override;
    function GetProperty(const Name: string; out Value: string): Boolean; override;
    function DefaultEncoding: string; override;
    function AllowSnapshotFieldPrefix(C: TJVMClass; Count: Integer): Boolean; override;
    function TimeMillis: Int64; override;
    function MonotonicMillis: Int64; override;
    function InvokeNative(VM: TJVM; Method: TJVMMethod; const Arguments: TArray<TJVMValue>): TJVMValue; override;
  end;

  TJ2MERuntime = class
  private
    FHost: TJ2MEHost;
    FVM: TJVM;
    FState: TJ2MEState;
    FMIDlet: Integer;
    FClassName, FError, FPendingLifecycle: string;
    FQueue, FEventQueue: TQueue<TJ2MEInvocation>;
    FCurrentCall, FCurrentEvent: TJ2MEInvocation;
    FEventContext: Integer;
    FFrameNumber: UInt64;
    FConsumedFlushes: UInt64;
    FFrameReady: Boolean;
    FSuspendedStartup: Boolean;
    FStopPending: Boolean;
    FRestoredState: Boolean;
    FPointerScreen: Integer;
    FMediaContext: Integer;
    FMediaCallRunning: Boolean;
    FMediaError, FRMSError: string;
    FMixBuffer: TArray<Int64>;
    FRMSContext: Integer;
    FRMSCallRunning: Boolean;
    FBluetoothContext: Integer;
    FBluetoothCallRunning: Boolean;
    FBluetoothError: string;
    FMessagingContext: Integer;
    FMessagingCallRunning: Boolean;
    FMessagingError: string;
    procedure Enqueue(const ClassName, Name, Descriptor: string; const Args: array of TJVMValue);
    procedure ApplyKeyEvent(KeyCode: Integer; Pressed: Boolean; IgnoreExecutionPause: Boolean = False);
    function HasPendingCanvasHide: Boolean;
    function TakePausedCanvasHide(out Job: TJ2MEInvocation): Boolean;
    function TakeDisplayEvent: TJ2MEInvocation;
    procedure CoalesceKeyEvents;
    procedure PollCustomKeyRepeats;
    procedure CancelPointer;
    procedure ClearQueue;
    procedure TransferState(S: TJVMStateIO);
    function GetBluetoothProvider: IBluetoothProvider;
    function GetMessagingProvider: IMessagingProvider;
    function GetLifecyclePauseRequested: Boolean;
  public
    constructor Create(Suite: TJ2MESuite; Width: Integer = 240; Height: Integer = 320; const Bluetooth: IBluetoothProvider = nil; const Messaging: IMessagingProvider = nil);
    destructor Destroy; override;
    procedure SaveState(Stream: TStream);
    class function LoadState(Suite: TJ2MESuite; Stream: TStream; const Bluetooth: IBluetoothProvider = nil; const Messaging: IMessagingProvider = nil; StartPaused: Boolean = False): TJ2MERuntime; static;
    procedure CommitRestoredState;
    procedure ReleasePhysicalKeys;
    procedure ReconcilePhysicalKeys(const DesiredKeys: TArray<Integer>);
    // On the VM owner thread. Compatibility migrations of ordinary Canvas saves.
    procedure ResizeCanvas(Width, Height: Integer);
    function ScreenRecommendation(out Size: TJ2MEScreenSize): Boolean;
    function ScreenWidth: Integer;
    function ScreenHeight: Integer;
    function IsFullscreenCanvas: Boolean;
    procedure Start(MIDletIndex: Integer = 0);
    procedure Tick(InstructionBudget: Integer);
    function NeedsExecution: Boolean;
    // Emulator suspension freezes execution/clocks without MIDlet callbacks.
    procedure SetExecutionPaused(Value: Boolean);
    procedure Pause;
    procedure Resume;
    procedure DestroyApp;
    procedure KeyEvent(KeyCode: Integer; Pressed: Boolean);
    procedure PointerEvent(const Event: TEmulationTouchEvent);
    function HasTouchCanvas: Boolean;
    function HasTouchInput: Boolean;
    procedure SetSensorInput(const Input: TJ2MESensorInput);
    function SensorInputRequested: Boolean;
    procedure TextInput(const Text: string);
    procedure RequestStop;
    function TakeFrame(out Pixels: TArray<UInt32>; out Number: UInt64): Boolean;
    function RenderAudio(Frames: Integer): TArray<SmallInt>;
    function TakeVibrationSample: TJ2MEVibrationSample;
    procedure CancelVibration;
    function TakeMediaError: string;
    function TakeRMSError: string;
    function TakeBluetoothError: string;
    function TakeLifecycleError: string;
    function TakeMessagingError: string;
    property State: TJ2MEState read FState;
    property Error: string read FError;
    property LifecyclePauseRequested: Boolean read GetLifecyclePauseRequested;
    property VM: TJVM read FVM;
    property MIDletReference: Integer read FMIDlet;
    property BluetoothProvider: IBluetoothProvider read GetBluetoothProvider;
    property MessagingProvider: IMessagingProvider read GetMessagingProvider;
  end;

implementation

uses
  System.DateUtils, System.Diagnostics, System.Types, Java.Classes,
  J2ME.Graphics, J2ME.Image, J2ME.Font, J2ME.GameCanvas, J2ME.Game.Layers,
  Core.Bluetooth, Core.Messaging, J2ME.Bluetooth.Data, J2ME.Siemens.Graphics,
  J2ME.Resources, J2ME.Vodafone.Device, J2ME.Vodafone.Micro3D, J2ME.M3G,
  J2ME.M3G.Graphics, J2ME.M3G.Loader, J2ME.Micro3D, J2ME.Micro3D.Texture,
  J2ME.Micro3D.Figure, J2ME.Micro3D.Action, J2ME.Micro3D.Graphics,
  J2ME.Compatibility, J2ME.UI.Data;

const
  DisplayClass = 'javax/microedition/lcdui/Display';
  RunFormSerially = '$runFormSerially';
  RunFormSeriallyDesc = '(Ljavax/microedition/lcdui/Form;Ljava/lang/Runnable;[Ljava/lang/Object;)V';
  CustomKeyInitialDelayMS = 400;
  CustomKeyRepeatIntervalMS = 100;

constructor TJ2MEHost.Create(Suite: TJ2MESuite; Width, Height: Integer; const Bluetooth: IBluetoothProvider; const Messaging: IMessagingProvider);
begin
  inherited Create;
  if Suite = nil then
    raise EArgumentNilException.Create('Suite');
  if (Width < 1) or (Width > 1024) or (Height < 1) or (Height > 1024) then
    raise EArgumentOutOfRangeException.Create('Java ME screen dimensions');
  FSuite := Suite;
  FKeyLayout := J2MECompatibilityKeyLayout(Suite);
  FNativePixelFormat := J2MECompatibilityNativePixelFormat(Suite);
  FExplicitInitialPaintClass := J2MECompatibilityExplicitInitialPaint(Suite);
  FEmptyGameURLTemplate := J2MECompatibilityEmptyGameURLTemplate(Suite);
  FStackAttack2 := J2MECompatibilityStackAttack2(Suite);
  FPlatformName := J2MECompatibilityPlatform(Suite);
  FSummerSki := J2MECompatibilitySummerSki(Suite);
  FMarslander := J2MECompatibilityMarslander(Suite);
  FLocale := J2MECompatibilityLocale(Suite);
  if FLocale = '' then
    if FSummerSki or FStackAttack2 or FMarslander then
      FLocale := 'en'
    else
      FLocale := 'en-US';
  if not TryJ2MECompatibilityEncoding(Suite, FDefaultEncoding) then
    FDefaultEncoding := inherited DefaultEncoding;
  FWidth := Width;
  FHeight := Height;
  FBluetooth := Bluetooth;
  if FBluetooth = nil then
    FBluetooth := CreateUnavailableBluetoothProvider;
  FMessagingProvider := Messaging;
  if FMessagingProvider = nil then
    FMessagingProvider := CreateUnavailableMessagingProvider;
  FPhysicalKeys := TDictionary<Integer, Boolean>.Create;
  FKnownPhysicalKeys := TDictionary<Integer, Boolean>.Create;
  FCustomKeyRepeats := TList<TJ2MECustomKeyRepeat>.Create;
  FDisplayChanges := TQueue<TJ2MEDisplayChange>.Create;
  FUIJobs := TQueue<TJ2MEInvocation>.Create;
  FLayoutHeight := Height;
  SetLength(FContentPixels, Width * Height);
  SetLength(FPixels, Width * Height);
  for var I := 0 to High(FPixels) do
  begin
    FPixels[I] := $FFFFFFFF;
    FContentPixels[I] := $FFFFFFFF;
  end;
end;

destructor TJ2MEHost.Destroy;
begin
  FMessaging.Free;
  FSiemens.Free;
  FNokiaSound.Free;
  FNokiaUI.Free;
  FEffects.Free;
  FBluetoothAPI.Free;
  FNetwork.Free;
  FSensors.Free;
  FFileSystem.Free;
  FUIJobs.Free;
  FUI.Free;
  FRMS.Free;
  FMedia.Free;
  FDisplayChanges.Free;
  FPhysicalKeys.Free;
  FKnownPhysicalKeys.Free;
  FCustomKeyRepeats.Free;
  inherited;
end;

procedure TJ2MEHost.Install(VM: TJVM);
var
  C: TJVMClass;
  B: TJavaClassBuilder;

  function AddClass(const Name, Parent: string): TJVMClass;
  begin
    Result := TJVMClass.Create;
    Result.Name := Name;
    Result.SuperName := Parent;
    VM.DefineClass(Result);
  end;

  procedure IntConstant(const Name: string; Value: Integer);
  var
    F: TJVMField;
  begin
    F := TJVMField.Create;
    F.Name := Name;
    F.Descriptor := 'I';
    F.Access := JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL;
    F.Value := TJVMValue.Int(Value);
    C.Fields.Add(F);
  end;

begin
  FVM := VM;
  FEffects := TJ2MEDeviceEffects.Create(MonotonicMillis, J2MECompatibilityIgnoredFlashDuration(FSuite));
  InstallJavaBootstrap(VM);
  InstallJ2MECompatibilityClasses(FSuite, VM, FArmiesOfWarClass);
  FMedia := TJ2MEMedia.Create(VM);
  FMedia.Install;
  FMedia.VideoBounds :=
    function(Screen: Integer): TRect
    begin
      var Top := FUI.Top(Screen);
      Result := Rect(0, Top, FUI.ContentWidth(Screen), Top + FUI.ContentHeight(Screen));
    end;
  FNetwork := TJ2MENetwork.Create(VM);
  FNetwork.Install;
  FSensors := TJ2MESensors.Create(VM);
  FSensors.Install;
  FFileSystem := TJ2MEFileSystem.Create(VM, FSuite.Storage,
    FSuite.GetProperty('MIDlet-Vendor'), FSuite.GetProperty('MIDlet-Name'));
  FFileSystem.Install;
  FMedia.Files := FFileSystem;
  InstallJ2MEResources(VM);
  FMessaging := TJ2MEMessaging.Create(VM, FMessagingProvider);
  FMessaging.Install(FSuite);
  FNetwork.ProtocolOpen :=
    function(URL: string; Mode: Integer; Timeouts: Boolean): Integer
    begin
      Result := -1;
      var P := Pos(':', URL);
      var Scheme := Copy(URL, 1, P - 1);
      if SameText(Scheme, 'sensor') then
        Exit(FSensors.Open(URL, Mode));
      if SameText(Scheme, 'file') then
        Exit(FFileSystem.Open(URL, Mode, FSummerSki));
      if SameText(Scheme, 'resource') then
        Result := OpenJ2MEResource(VM, URL, Mode, FSummerSki);
      if SameText(Scheme, 'sms') or SameText(Scheme, 'cbs') then
        Result := FMessaging.Open(URL, Mode, Timeouts);
      if SameText(Scheme, 'btspp') or SameText(Scheme, 'btl2cap') then
        Result := FBluetoothAPI.Open(URL, Mode, Timeouts);
    end;
  InstallJ2MEBluetoothData(VM);
  FBluetoothAPI := TJ2MEBluetooth.Create(VM, FBluetooth);
  FBluetoothAPI.Install;
  FRMS := TJ2MERMS.Create(VM, FSuite.Storage, FSuite.GetProperty('MIDlet-Vendor'), FSuite.GetProperty('MIDlet-Name'));
  FRMS.Install;
  C := AddClass('javax/microedition/midlet/MIDlet', 'java/lang/Object');
  C.Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
  C.AddNative('<init>', '()V').Access := JVM_ACC_PROTECTED or JVM_ACC_NATIVE;
  C.AddNative('getAppProperty', '(Ljava/lang/String;)Ljava/lang/String;').Access := JVM_ACC_PUBLIC or JVM_ACC_FINAL or JVM_ACC_NATIVE;
  for var N in ['notifyDestroyed', 'notifyPaused', 'resumeRequest'] do
    C.AddNative(N, '()V').Access := JVM_ACC_PUBLIC or JVM_ACC_FINAL or JVM_ACC_NATIVE;
  C.AddNative('platformRequest', '(Ljava/lang/String;)Z').Access := JVM_ACC_PUBLIC or JVM_ACC_FINAL or JVM_ACC_NATIVE;
  C.AddNative('checkPermission', '(Ljava/lang/String;)I').Access := JVM_ACC_PUBLIC or JVM_ACC_FINAL or JVM_ACC_NATIVE;
  C.AddNative('startApp', '()V').Access := JVM_ACC_PROTECTED or JVM_ACC_ABSTRACT;
  C.AddNative('pauseApp', '()V').Access := JVM_ACC_PROTECTED or JVM_ACC_ABSTRACT;
  C.AddNative('destroyApp', '(Z)V').Access := JVM_ACC_PROTECTED or JVM_ACC_ABSTRACT;
  C := AddClass('javax/microedition/midlet/MIDletStateChangeException', 'java/lang/Exception');
  C.AddNative('<init>', '()V');
  C.AddNative('<init>', '(Ljava/lang/String;)V');
  B := TJavaClassBuilder.Create('javax/microedition/midlet/MIDlet$Lifecycle', 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL or $20);
  try
    B.JavaClass.AddNative('$failure', '(Ljava/lang/Throwable;I)Z', True).Access := JVM_ACC_PRIVATE or JVM_ACC_STATIC or JVM_ACC_NATIVE;
    for var Phase := 1 to 3 do
    begin
      var Name := 'startApp';
      if Phase = 2 then
        Name := 'pauseApp'
      else if Phase = 3 then
        Name := 'destroyApp';
      B.Start;
      B.Mark('call');
      B.Emit([$2A]);
      if Phase = 3 then
        B.Emit([$1B]);
      var CallDesc := '()V';
      if Phase = 3 then
        CallDesc := '(Z)V';
      B.Ref($B6, B.Member('javax/microedition/midlet/MIDlet', Name, CallDesc));
      B.Mark('returned');
      B.Emit([$03, $AC]);
      if Phase = 1 then
      begin
        B.Mark('deferred');
        B.Emit([$57, $04, $AC]);
      end;
      B.Mark('failed');
      B.Emit([$4D, $2C, Byte($03 + Phase)]);
      B.Ref($B8, B.Member('javax/microedition/midlet/MIDlet$Lifecycle', '$failure', '(Ljava/lang/Throwable;I)Z'));
      if Phase <> 3 then
      begin
        B.Jump($99, 'done');
        B.Mark('cleanup');
        B.Emit([$2A, $04]);
        B.Ref($B6, B.Member('javax/microedition/midlet/MIDlet', 'destroyApp', '(Z)V'));
        B.Mark('cleaned');
        B.Jump($A7, 'done');
        B.Mark('ignored');
        B.Emit([$57]);
      end
      else
        B.Emit([$57]);
      B.Mark('done');
      B.Emit([$05, $AC]);
      var Desc := '(Ljavax/microedition/midlet/MIDlet;)I';
      if Phase = 3 then
        Desc := '(Ljavax/microedition/midlet/MIDlet;Z)I';
      B.Finish(Name, Desc, JVM_ACC_PUBLIC or JVM_ACC_STATIC, 2, 3);
      var H: TJVMExceptionHandler;
      H := Default(TJVMExceptionHandler);
      H.StartPC := B.Position('call');
      H.EndPC := B.Position('returned');
      H.HandlerPC := B.Position('failed');
      var Handlers: TArray<TJVMExceptionHandler> := [];
      if Phase = 1 then
      begin
        var Deferred := H;
        Deferred.HandlerPC := B.Position('deferred');
        Deferred.CatchType := B.ClassRef('javax/microedition/midlet/MIDletStateChangeException');
        Handlers := Handlers + [Deferred];
      end;
      Handlers := Handlers + [H];
      if Phase <> 3 then
      begin
        H.StartPC := B.Position('cleanup');
        H.EndPC := B.Position('cleaned');
        H.HandlerPC := B.Position('ignored');
        Handlers := Handlers + [H];
      end;
      B.JavaClass.Methods.Last.Handlers := Handlers;
    end;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  FUI := TJ2MELCDUI.Create(VM, FWidth, FHeight,
    procedure(Screen: Integer)
    begin
      ChangeScreen(Screen);
    end,
    procedure(Screen, Generation: Integer)
    begin
      PostAlertTimeout(Screen, Generation);
    end,
    procedure(Screen: Integer)
    begin
      QueueUI('javax/microedition/lcdui/Form', '$drain', '()V', [TJVMValue.Ref(Screen)]);
    end);
  FUI.OnCustomKeyPressed :=
    procedure(Code, Item: Integer)
    begin
      if FPhysicalKeys.ContainsKey(Code) and (CustomKeyRepeatIndex(Code) < 0) then
      begin
        var Held: TJ2MECustomKeyRepeat;
        Held.Code := Code;
        Held.Item := Item;
        Held.Next := MonotonicMillis + CustomKeyInitialDelayMS;
        FCustomKeyRepeats.Add(Held);
      end;
    end;
  FUI.PostCustomItem :=
    procedure(const Name, Descriptor: string; const Args: array of TJVMValue)
    begin
      QueueUI('javax/microedition/lcdui/CustomItem', Name, Descriptor, Args);
    end;
  FUI.DrawVideoItem :=
    procedure(Item: Integer; var Pixels: TArray<UInt32>; Stride, X, Y: Integer; const Clip: TRect)
    begin
      FMedia.DrawVideoItem(Item, Pixels, Stride, X, Y, Clip);
    end;
  FUI.CanvasKeyLayout := FKeyLayout;
  FUI.ReserveCanvasFooter := J2MECompatibilityCanvasFooter(FSuite);
  FUI.Install;
  var CanvasCallbackAccess: Word := JVM_ACC_PRIVATE or JVM_ACC_SYNCHRONIZED;
  if J2MECompatibilityUsesOwnCanvasLock(FSuite) then
    CanvasCallbackAccess := JVM_ACC_PRIVATE;
  B := TJavaClassBuilder.Create('javax/microedition/lcdui/Canvas', 'javax/microedition/lcdui/Displayable');
  try
    C := B.JavaClass;
    C.Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    C.AddNative('<init>', '()V');
    C.AddNative('repaint', '()V');
    C.AddNative('repaint', '(IIII)V');
    C.AddNative('serviceRepaints', '()V').Access := JVM_ACC_PUBLIC or JVM_ACC_FINAL or JVM_ACC_NATIVE;
    C.AddNative('$beginPaint', '(Ljavax/microedition/lcdui/Graphics;)Z').Access := JVM_ACC_PRIVATE or JVM_ACC_NATIVE;
    C.AddNative('$visibility', '(Z)V').Access := JVM_ACC_PRIVATE or JVM_ACC_NATIVE;
    C.AddNative('$pointerReady', '()Z').Access := JVM_ACC_PRIVATE or JVM_ACC_NATIVE;
    C.AddNative('$size', '()V').Access := JVM_ACC_PRIVATE or JVM_ACC_NATIVE;
    C.AddNative('$painted', '()V').Access := JVM_ACC_PRIVATE or JVM_ACC_NATIVE;
    C.AddNative('paint', '(Ljavax/microedition/lcdui/Graphics;)V').Access := JVM_ACC_PROTECTED or JVM_ACC_ABSTRACT;
    C.AddNative('setFullScreenMode', '(Z)V');
    C.AddNative('isDoubleBuffered', '()Z');
    C.AddNative('keyPressed', '(I)V');
    C.AddNative('keyReleased', '(I)V');
    C.AddNative('keyRepeated', '(I)V');
    C.AddNative('showNotify', '()V');
    C.AddNative('hideNotify', '()V');
    C.AddNative('getGameAction', '(I)I');
    C.AddNative('getKeyCode', '(I)I');
    C.AddNative('getKeyName', '(I)Ljava/lang/String;');
    for var N in ['hasPointerEvents', 'hasPointerMotionEvents', 'hasRepeatEvents'] do
      C.AddNative(N, '()Z');
    for var N in ['pointerPressed', 'pointerReleased', 'pointerDragged', 'sizeChanged'] do
      C.AddNative(N, '(II)V').Access := JVM_ACC_PROTECTED or JVM_ACC_NATIVE;
    for var M in C.Methods do
      if (M.Name = 'keyPressed') or (M.Name = 'keyReleased') or (M.Name = 'keyRepeated') or
        (M.Name = 'showNotify') or (M.Name = 'hideNotify') then
        M.Access := JVM_ACC_PROTECTED or JVM_ACC_NATIVE;
    IntConstant('UP', 1);
    IntConstant('DOWN', 6);
    IntConstant('LEFT', 2);
    IntConstant('RIGHT', 5);
    IntConstant('FIRE', 8);
    IntConstant('GAME_A', 9);
    IntConstant('GAME_B', 10);
    IntConstant('GAME_C', 11);
    IntConstant('GAME_D', 12);
    for var I := 0 to 9 do
      IntConstant('KEY_NUM' + IntToStr(I), 48 + I);
    IntConstant('KEY_STAR', 42);
    IntConstant('KEY_POUND', 35);
    // Ordinary guest bytecode keeps synchronous and nested paint resumable.
    // Each delivery has its own Graphics, including serviceRepaints in paint().
    B.Start;
    B.Emit([$2A, $2B]);
    B.Ref($B7, B.Member(C.Name, '$beginPaint', '(Ljavax/microedition/lcdui/Graphics;)Z'));
    B.Jump($99, 'done');
    B.Emit([$2A, $2B]);
    B.Ref($B6, B.Member(C.Name, 'paint', '(Ljavax/microedition/lcdui/Graphics;)V'));
    B.Emit([$2A]);
    B.Ref($B7, B.Member(C.Name, '$painted', '()V'));
    B.Mark('done');
    B.Emit([$B1]);
    // UI delivery and background serviceRepaints must not enter paint at
    // the same time. A reentrant monitor still permits repaint from paint.
    B.Finish('$deliverPaint', '(Ljavax/microedition/lcdui/Graphics;)V',
      CanvasCallbackAccess, 2, 2);
    // Key callbacks share the paint monitor. A background serviceRepaints
    // must not let paint overwrite input arriving halfway through that paint.
    B.Start;
    B.Emit([$1C]);
    B.Jump($99, 'released');
    B.Emit([$2A, $1B]);
    B.Ref($B6, B.Member(C.Name, 'keyPressed', '(I)V'));
    B.Emit([$B1]);
    B.Mark('released');
    B.Emit([$2A, $1B]);
    B.Ref($B6, B.Member(C.Name, 'keyReleased', '(I)V'));
    B.Emit([$B1]);
    B.Finish('$deliverKey', '(IZ)V', CanvasCallbackAccess, 2, 3);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member(C.Name, '$pointerReady', '()Z'));
    B.Jump($99, 'pointerDone');
    B.Emit([$1B]);
    B.Jump($99, 'pointerDown');
    B.Emit([$1B, $04]);
    B.Jump($9F, 'pointerMove');
    B.Emit([$2A, $1C, $1D]);
    B.Ref($B6, B.Member(C.Name, 'pointerReleased', '(II)V'));
    B.Emit([$B1]);
    B.Mark('pointerDown');
    B.Emit([$2A, $1C, $1D]);
    B.Ref($B6, B.Member(C.Name, 'pointerPressed', '(II)V'));
    B.Emit([$B1]);
    B.Mark('pointerMove');
    B.Emit([$2A, $1C, $1D]);
    B.Ref($B6, B.Member(C.Name, 'pointerDragged', '(II)V'));
    B.Mark('pointerDone');
    B.Emit([$B1]);
    // All input callbacks share the same monitor as paint/key callbacks.
    B.Finish('$deliverPointer', '(III)V', CanvasCallbackAccess, 3, 4);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  C := AddClass('javax/microedition/lcdui/Display', 'java/lang/Object');
  IntConstant('LIST_ELEMENT', 1);
  IntConstant('CHOICE_GROUP_ELEMENT', 2);
  IntConstant('ALERT', 3);
  IntConstant('COLOR_BACKGROUND', 0);
  IntConstant('COLOR_FOREGROUND', 1);
  IntConstant('COLOR_HIGHLIGHTED_BACKGROUND', 2);
  IntConstant('COLOR_HIGHLIGHTED_FOREGROUND', 3);
  IntConstant('COLOR_BORDER', 4);
  IntConstant('COLOR_HIGHLIGHTED_BORDER', 5);
  C.AddNative('getColor', '(I)I');
  C.AddNative('getBorderStyle', '(Z)I');
  C.AddNative('getBestImageWidth', '(I)I');
  C.AddNative('getBestImageHeight', '(I)I');
  C.AddNative('getDisplay', '(Ljavax/microedition/midlet/MIDlet;)Ljavax/microedition/lcdui/Display;', True);
  C.AddNative('setCurrent', '(Ljavax/microedition/lcdui/Displayable;)V');
  C.AddNative('setCurrent', '(Ljavax/microedition/lcdui/Alert;Ljavax/microedition/lcdui/Displayable;)V');
  C.AddNative('getCurrent', '()Ljavax/microedition/lcdui/Displayable;');
  C.AddNative('setCurrentItem', '(Ljavax/microedition/lcdui/Item;)V');
  C.AddNative('isColor', '()Z');
  C.AddNative('numColors', '()I');
  C.AddNative('numAlphaLevels', '()I');
  C.AddNative('numGrayLevels', '()I');
  C.AddNative('callSerially', '(Ljava/lang/Runnable;)V');
  C.AddNative('$runSerially', '(Ljavax/microedition/lcdui/Canvas;Ljava/lang/Runnable;)V', True).Access :=
    JVM_ACC_PRIVATE or JVM_ACC_STATIC or JVM_ACC_NATIVE;
  C.AddNative(RunFormSerially, RunFormSeriallyDesc, True).Access :=
    JVM_ACC_PRIVATE or JVM_ACC_STATIC or JVM_ACC_NATIVE;
  C.AddNative('vibrate', '(I)Z');
  C.AddNative('flashBacklight', '(I)Z');
  C := AddClass('com/samsung/util/Vibration', 'java/lang/Object');
  C.Access := JVM_ACC_PUBLIC or JVM_ACC_FINAL;
  C.AddNative('isSupported', '()Z', True);
  C.AddNative('start', '(II)V', True);
  C.AddNative('stop', '()V', True);
  FSamsungVibrationMillis := J2MECompatibilitySamsungVibrationMillis(FSuite);
  InstallJ2MEGraphics(VM);
  InstallJ2MEImage(VM);
  InstallJ2MEFont(VM);
  InstallJ2MEGameCanvas(VM);
  InstallJ2MEGameLayers(VM);
  InstallJ2MEGameCanvas(VM, True);
  InstallJ2MEGameLayers(VM, True);
  InstallJ2MEVodafoneDevice(VM);
  InstallJ2MEM3G(VM);
  InstallJ2MEMicro3D(VM);
  InstallJ2MEMicro3DTextures(VM);
  InstallJ2MEMicro3DFigure(VM);
  InstallJ2MEMicro3DAction(VM);
  InstallJ2MEMicro3DGraphics(VM);
  InstallJ2MEVodafoneMicro3D(VM);
  FNokiaUI := TJ2MENokiaUI.Create(VM, FEffects);
  FNokiaUI.Install;
  FNokiaSound := TJ2MENokiaSound.Create(VM);
  FNokiaSound.Install(FSuite);
  FSiemens := TJ2MESiemensGame.Create(VM, FEffects);
  FSiemens.Install;
  InstallJ2MESiemensGraphics(VM);
  FDisplay := VM.NewObject('javax/microedition/lcdui/Display');
  VM.AddRoot(FDisplay);
end;

procedure TJ2MEHost.PrepareClass(C: TJVMClass);
begin
  PrepareJ2MEFrameTimers(C);
end;

function TJ2MEHost.LoadClass(const Name: string): TBytes;
begin
  Result := FSuite.LoadClass(Name);
end;

function TJ2MEHost.LoadResource(const Name: string; out Data: TBytes): Boolean;
var
  Key: string;
begin
  Data := nil;
  Result := False;
  var Path := Name;
  var ResourcePath := Path;
  if ResourcePath.StartsWith('/') then
    Delete(ResourcePath, 1, 1);
  if (FStackAttack2 and ResourcePath.StartsWith('StackAttack2\')) or
    (FMarslander and ResourcePath.StartsWith('res\')) then
    Path := Path.Replace('\', '/');
  if not J2MECanonicalResourceName(Path, Key) then
    Exit;
  if FSummerSki and (Key = 'sound/intro.mid') and not FSuite.HasResource(Key) then
    Key := 'sound/_intro.mid';
  // MIDP resources cannot expose classfiles. Class loading uses LoadClass instead.
  if Key.EndsWith('.class') then
    Exit;
  Result := FSuite.HasResource(Key);
  if Result then
    Data := NormalizeJ2MECompatibilityResource(Key, FSuite.ReadResource(Key));
end;

function TJ2MEHost.LoadClassResource(const ClassName, Name: string; out Data: TBytes): Boolean;
begin
  // Keep the raw leading slash until MIDP canonicalization, including repeated
  // separators. The reusable Java host keeps its existing unrooted-key contract.
  Result := LoadResource(JavaClassResourceName(ClassName, Name), Data);
end;

function TJ2MEHost.TimeMillis: Int64;
var
  Current: TDateTime;
begin
  if FExecutionPaused then
    Exit(FExecutionWall);
  Current := Now;
  Result := DateTimeToUnix(TTimeZone.local.ToUniversalTime(Current), True) * 1000 + MilliSecondOf(Current) + FWallOffset;
end;

function TJ2MEHost.AllowSnapshotFieldPrefix(C: TJVMClass; Count: Integer): Boolean;
begin
  // Figure snapshots predating MTRA have nine fields and no current pose.
  // Display snapshots from before its LCDUI appearance constants had no fields.
  Result := ((C.Name = 'javax/microedition/lcdui/Display') and (Count = 0)) or
    (J2MEMicro3DFigureHandles(C.Name) and (Count = 9)) or
    TJ2MEMedia.SupportsLegacyClassLayout(C, Count) or TJ2MEMessaging.SupportsLegacyClassLayout(C, Count) or
    inherited AllowSnapshotFieldPrefix(C, Count);
end;

function TJ2MEHost.DefaultEncoding: string;
begin
  Result := FDefaultEncoding;
end;

function TJ2MEHost.GetProperty(const Name: string; out Value: string): Boolean;
begin
  Result := True;
  if (FFileSystem <> nil) and FFileSystem.GetProperty(Name, Value) then
    Exit(True);
  if (FMessaging <> nil) and FMessaging.GetProperty(Name, Value) then
    Exit(True);
  if Name = 'microedition.platform' then
    Value := FPlatformName
  else if Name = 'microedition.configuration' then
    Value := 'CLDC-1.1'
  else if Name = 'microedition.profiles' then
    Value := 'MIDP-2.0'
  else if Name = 'microedition.m3g.version' then
    Value := '1.1'
  else if Name = 'video.snapshot.encodings' then
    Value := J2MEVideoSnapshotEncodings
  else if (Name = 'microedition.sensor.version') and FSensors.Input.Available then
    Value := '1.0'
  else if Name = 'supports.video.capture' then
    Value := 'false'
  else if Name = 'microedition.encoding' then
    Value := DefaultEncoding
  else if Name = 'microedition.locale' then
    Value := FLocale
  else
    Result := inherited GetProperty(Name, Value);
end;

function TJ2MEHost.MonotonicMillis: Int64;
var
  Stamp, Frequency: Int64;
begin
  if FExecutionPaused then
    Exit(FExecutionMono);
  Stamp := TStopwatch.GetTimeStamp;
  Frequency := TStopwatch.Frequency;
  Result := (Stamp div Frequency) * 1000 + ((Stamp mod Frequency) * 1000) div Frequency + FMonotonicOffset;
end;

function TJ2MEHost.InvokeNative(VM: TJVM; Method: TJVMMethod; const Arguments: TArray<TJVMValue>): TJVMValue;
var
  C, N, S: string;
  I: Integer;
  Flushed, Shown: Boolean;
  GuestResult: TJVMValue;

  function Arg(Index: Integer): TJVMValue;
  begin
    Result := Arguments[Index];
  end;

begin
  C := Method.Owner.Name;
  N := Method.Name;
  Result := Default(TJVMValue);
  if Method.Owner = FArmiesOfWarClass then
  begin
    InvokeArmiesOfWarCompatibility(VM, Method, Arguments);
    Exit;
  end;
  if C = 'javax/microedition/m3g/Loader' then
    Exit(InvokeM3GLoader(VM, FSuite, Method, Arguments));
  if C = 'javax/microedition/m3g/Graphics3D' then
    Exit(InvokeM3GGraphics(VM, Method, Arguments, FContentPixels, FWidth, FUI.ContentHeight(FScreen)));
  if J2MEM3GHandles(C) then
    Exit(InvokeJ2MEM3G(VM, Method, Arguments));
  if J2MEMicro3DHandles(C) then
    Exit(InvokeJ2MEMicro3D(VM, Method, Arguments));
  if C = Micro3DGraphicsName then
    Exit(InvokeJ2MEMicro3DGraphics(VM, Method, Arguments, FContentPixels, FWidth, FUI.ContentHeight(FScreen)));
  if J2MEMicro3DFigureHandles(C) then
    Exit(InvokeJ2MEMicro3DFigure(VM, FSuite, Method, Arguments));
  if C = Micro3DActionName then
    Exit(InvokeJ2MEMicro3DAction(VM, FSuite, Method, Arguments));
  if J2MEMicro3DTextureHandles(C) then
    Exit(InvokeJ2MEMicro3DTexture(VM, FSuite, Method, Arguments));
  if HandlesJ2MEVodafoneMicro3D(C, N) then
    Exit(InvokeJ2MEVodafoneMicro3D(VM, FSuite, Method, Arguments, FContentPixels, FWidth, FUI.ContentHeight(FScreen), FRootMIDlet));
  if HandlesJ2MEVodafoneDevice(C) then
    Exit(InvokeJ2MEVodafoneDevice(VM, FEffects, Method, Arguments, FPhysicalKeys));
  if FSiemens.Handles(C) then
    Exit(FSiemens.Invoke(Method, Arguments));
  if HandlesJ2MESiemensGraphics(C) then
  begin
    Result := InvokeJ2MESiemensGraphics(VM, Method, Arguments, FContentPixels, FWidth, FHeight, Flushed);
    if Flushed then
    begin
      FPixels := Copy(FContentPixels);
      FHasContent := True;
      Inc(FFlushCount);
    end;
    Exit;
  end;
  if C = 'com/samsung/util/Vibration' then
  begin
    if N = 'isSupported' then
      Exit(TJVMValue.Int(1));
    if N = 'start' then
    begin
      var Duration := Int64(Arg(0).AsInt);
      var Strength := Arg(1).AsInt;
      if (Duration <= 0) or (Strength < 1) or (Strength > 5) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Samsung vibration duration or strength');
      if not FSamsungVibrationMillis then
        Duration := Duration * 1000;
      // The Samsung API validates the strength; its reference devices use
      // one vibration level.
      if HasDisplayForeground then
        FEffects.SetVibration(100, Duration, MonotonicMillis);
    end
    else
      FEffects.SetVibration(0, 0, MonotonicMillis);
    Exit;
  end;
  if FNokiaSound.Handles(C) then
    Exit(FNokiaSound.Invoke(Method, Arguments));
  if FNokiaUI.Handles(C) then
    Exit(FNokiaUI.Invoke(Method, Arguments));
  if FMessaging.Handles(Method.Owner.Name) then
    Exit(FMessaging.Invoke(Method, Arguments));
  if HandlesJ2MEResources(C) then
    Exit(InvokeJ2MEResources(VM, Method, Arguments));
  if FFileSystem.Handles(C) then
    Exit(FFileSystem.Invoke(Method, Arguments));
  if FSensors.Handles(C) then
    Exit(FSensors.Invoke(FRootMIDlet, Method, Arguments));
  if FNetwork.Handles(Method) then
    Exit(FNetwork.Invoke(Method, Arguments));
  if HandlesJ2MEBluetoothData(C) then
    Exit(InvokeJ2MEBluetoothData(VM, Method, Arguments));
  if FBluetoothAPI.Handles(C) then
    Exit(FBluetoothAPI.Invoke(Method, Arguments));
  if (C = J2MECustomItemClass) and (N = '$repeatKey') then
  begin
    var Code := Arg(1).AsInt;
    var Index := CustomKeyRepeatIndex(Code);
    if (Index < 0) or (FCustomKeyRepeats[Index].Item <> Arg(0).AsRef) or
      (FUI.CustomKeyTarget(FScreen, Code) <> Arg(0).AsRef) then
      Exit;
  end;
  if (N = 'isShown') and ((C = 'javax/microedition/lcdui/Displayable') or (C = 'javax/microedition/lcdui/Canvas')) then
    Exit(TJVMValue.Int(Ord(IsDisplayShown(Arg(0).AsRef))));
  if (C = 'javax/microedition/lcdui/Displayable') and (N = '$key') and not HasDisplayForeground then
    Exit;
  if FUI.Handles(C) then
  begin
    var BeforeScreen := FScreen;
    I := FUI.ContentHeight(FScreen);
    Shown := FUI.IsShown(FScreen);
    Result := FUI.Invoke(Method, Arguments);
    if BeforeScreen <> FScreen then
      Exit;
    if Shown <> FUI.IsShown(FScreen) then
    begin
      if FUI.IsCanvas(FScreen) then
      begin
        J2MEClearGameKeys(VM.GetObject(FScreen));
        QueueUI('javax/microedition/lcdui/Canvas', '$visibility', '(Z)V', [TJVMValue.Ref(FScreen), TJVMValue.Int(Ord(FUI.IsShown(FScreen)))]);
      end;
      FRepaint := True;
    end;
    if (FScreen <> 0) and (I <> FUI.ContentHeight(FScreen)) then
    begin
      FLayoutHeight := FUI.ContentHeight(FScreen);
      FRepaint := True;
      if FUI.IsCanvas(FScreen) then
        QueueUI('javax/microedition/lcdui/Canvas', '$size', '()V', [TJVMValue.Ref(FScreen)])
      else
        QueueUI(VM.GetObject(FScreen).ClassName, 'sizeChanged', '(II)V', [TJVMValue.Ref(FScreen), TJVMValue.Int(FUI.ContentWidth(FScreen)), TJVMValue.Int(FLayoutHeight)]);
    end;
    Exit;
  end;
  if FRMS.Handles(C) then
    Exit(FRMS.Invoke(Method, Arguments));
  if FMedia.Handles(C) then
    Exit(FMedia.Invoke(Method, Arguments));
  if C = 'javax/microedition/lcdui/Image' then
    Exit(InvokeJ2MEImage(VM, Method, Arguments));
  if C = 'javax/microedition/lcdui/Font' then
    Exit(InvokeJ2MEFont(VM, Method, Arguments));
  if J2MEGameCanvasHandles(C) then
  begin
    // The dedicated GameCanvas buffer has maximum phone dimensions, including
    // when it is constructed while a smaller displayable is current. Only the
    // region copied to the screen uses this canvas's current content height.
    I := FUI.ContentHeight(Arg(0).AsRef);
    if N = '<init>' then
      I := FHeight;
    Result := InvokeJ2MEGameCanvas(VM, Method, Arguments, IsDisplayShown(Arg(0).AsRef), FContentPixels, FWidth, I, Flushed);
    if Flushed then
    begin
      FHasContent := True;
      FUI.Render(FPixels, FContentPixels, MonotonicMillis);
      Inc(FFlushCount);
    end;
    Exit;
  end;
  if J2MEGameLayersHandles(C) then
    Exit(InvokeJ2MEGameLayers(VM, Method, Arguments, FContentPixels, FWidth, FUI.ContentHeight(FScreen)));
  if C = 'javax/microedition/midlet/MIDlet$Lifecycle' then
  begin
    var O := VM.GetObject(Arg(0).AsRef);
    var Phase := 'startApp';
    if Arg(1).AsInt = 2 then
      Phase := 'pauseApp'
    else if Arg(1).AsInt = 3 then
      Phase := 'destroyApp';
    if (Arg(1).AsInt = 3) and VM.IsAssignable(O.ClassName, 'javax/microedition/midlet/MIDletStateChangeException') then
    begin
      FResumeRequested := False;
      FMIDletStarted := False;
      Exit(TJVMValue.Int(0));
    end;
    FLifecycleError := Copy(Phase + ': ' + O.ClassName + ': ' + O.Text + #10 + O.ThrowableTrace, 1, 4096);
    FResumeRequested := False;
    FMIDletStarted := False;
    Exit(TJVMValue.Int(Ord(not FNotifyDestroyed)));
  end;
  if C = 'javax/microedition/midlet/MIDlet' then
  begin
    if N = '<init>' then
    begin
      if (FRootMIDlet = 0) or (Arg(0).AsRef <> FRootMIDlet) then
        VM.RaiseJava('java/lang/SecurityException', 'MIDlet creation is owned by the application manager');
      Exit;
    end;
    if N = 'notifyDestroyed' then
    begin
      FNotifyDestroyed := True;
      FResumeRequested := False;
      Exit;
    end;
    if N = 'notifyPaused' then
    begin
      if FMIDletStarted and not FNotifyDestroyed then
      begin
        FNotifyPaused := True;
        FGuestPaused := True;
        HideCurrentCanvas;
      end;
      Exit;
    end;
    if N = 'resumeRequest' then
    begin
      if FMIDletStarted and FGuestPaused and not FNotifyDestroyed then
        FResumeRequested := True;
      Exit;
    end;
    if N = 'platformRequest' then
    begin
      S := VM.GetObject(Arg(1).AsRef).Text;
      if S = '' then
        Exit(TJVMValue.Int(0));
      VM.RaiseJava('javax/microedition/io/ConnectionNotFoundException', 'No external application handler');
    end;
    if N = 'checkPermission' then
    begin
      S := VM.GetObject(Arg(1).AsRef).Text;
      var Permission := FMessaging.Permission(S);
      if Permission >= 0 then
        Exit(TJVMValue.Int(Permission));
      Exit(TJVMValue.Int(Ord((S = 'javax.microedition.io.Connector.http') or
            (S = 'javax.microedition.io.Connector.https') or
            (S = 'javax.microedition.io.Connector.datagram') or
            (S = 'javax.microedition.io.Connector.datagramreceive') or
            (S = 'javax.microedition.io.Connector.socket') or
            (S = 'javax.microedition.io.Connector.serversocket') or
            (S = 'javax.microedition.io.Connector.file.read') or
            (S = 'javax.microedition.io.Connector.file.write'))));
    end;
    if N = 'getAppProperty' then
    begin
      S := VM.GetObject(Arg(1).AsRef).Text;
      if FSuite.HasProperty(S) then
        Exit(TJVMValue.Ref(VM.NewString(FSuite.GetProperty(S))));
      if FEmptyGameURLTemplate and (S = 'URL-TEMPLATE-GAME') then
        Exit(TJVMValue.Ref(VM.InternString('')));
      var DefaultValue: string;
      if TryJ2MECompatibilityAppProperty(FSuite, S, DefaultValue) then
        Exit(TJVMValue.Ref(VM.NewString(DefaultValue)));
      Exit(TJVMValue.Ref(0));
    end;
  end;
  if C = 'javax/microedition/lcdui/Display' then
  begin
    if N = 'getDisplay' then
    begin
      VM.GetObject(Arg(0).AsRef);
      Exit(TJVMValue.Ref(FDisplay));
    end;
    if N = 'getCurrent' then
      Exit(TJVMValue.Ref(FScreen));
    if N = 'callSerially' then
    begin
      var Runnable := VM.GetObject(Arg(1).AsRef);
      if IsDisplayShown(FScreen) and FUI.IsCanvas(FScreen) and not WaitingForInitialPaint(VM.GetObject(FScreen)) then
        QueueUI(C, '$runSerially', '(Ljavax/microedition/lcdui/Canvas;Ljava/lang/Runnable;)V',
          [TJVMValue.Ref(FScreen), Arg(1)])
      else
      begin
        var Targets := 0;
        if IsDisplayShown(FScreen) then
          Targets := FUI.CapturePendingCustomPaints(FScreen);
        if Targets <> 0 then
          QueueUI(C, RunFormSerially, RunFormSeriallyDesc, [TJVMValue.Ref(FScreen), Arg(1), TJVMValue.Ref(Targets)])
        else
          QueueUI(Runnable.ClassName, 'run', '()V', [Arg(1)]);
      end;
      Exit;
    end;
    if (N = '$runSerially') or (N = RunFormSerially) then
    begin
      if (N = '$runSerially') and not VM.TakeGuestResult(GuestResult) then
      begin
        // serviceRepaints waits for a paint started on a different guest
        // thread even while its callback has temporarily released the monitor.
        var Canvas := VM.LoadClass('javax/microedition/lcdui/Canvas');
        VM.InvokeGuestResult(Canvas.FindMethod('serviceRepaints', '()V'), [Arg(0)]);
        Exit;
      end;
      var Runnable := VM.GetObject(Arg(1).AsRef);
      VM.InvokeGuest(VM.ResolveMethod(VM.LoadClass(Runnable.ClassName), 'run', '()V'), [Arg(1)]);
      Exit;
    end;
    if (N = 'vibrate') or (N = 'flashBacklight') then
    begin
      if Arg(1).AsInt < 0 then
        VM.RaiseJava('java/lang/IllegalArgumentException');
      if not HasDisplayForeground then
        Exit(TJVMValue.Int(0));
      if N = 'vibrate' then
        FEffects.SetVibration(100, Arg(1).AsInt, MonotonicMillis)
      else
        FEffects.FlashBacklight(Arg(1).AsInt, MonotonicMillis);
      Exit(TJVMValue.Int(1));
    end;
    if N = 'setCurrentItem' then
    begin
      FUI.FocusItem(Arg(1).AsRef);
      Exit;
    end;
    if N = 'setCurrent' then
    begin
      I := Arg(1).AsRef;
      if Length(Arguments) = 3 then
      begin
        VM.GetObject(I);
        VM.GetObject(Arg(2).AsRef);
        if FUI.IsAlert(Arg(2).AsRef) then
          VM.RaiseJava('java/lang/IllegalArgumentException', 'Alert return screen cannot be an Alert');
        FUI.ConfigureAlert(I, Arg(2).AsRef);
      end
      else
      begin
        if I = 0 then
          Exit;
        if FUI.IsAlert(I) then
        begin
          if FUI.IsAlert(FScreen) then
            VM.RaiseJava('java/lang/IllegalArgumentException', 'Current screen is already an Alert');
          FUI.ConfigureAlert(I, FScreen);
        end;
      end;
      ChangeScreen(I);
      Exit;
    end;
    if N = 'getColor' then
      Exit(TJVMValue.Int(FUI.DisplayColor(Arg(1).AsInt)));
    if N = 'getBorderStyle' then
      Exit(TJVMValue.Int(0)); // Both LCDUI border styles are Graphics.SOLID.
    if (N = 'getBestImageWidth') or (N = 'getBestImageHeight') then
    begin
      var ImageSize := FUI.BestImageSize(Arg(1).AsInt);
      if N = 'getBestImageWidth' then
        Exit(TJVMValue.Int(ImageSize.cx));
      Exit(TJVMValue.Int(ImageSize.cy));
    end;
    if N = 'isColor' then
      Exit(TJVMValue.Int(1));
    if N = 'numColors' then
      Exit(TJVMValue.Int(16777216));
    if (N = 'numAlphaLevels') or (N = 'numGrayLevels') then
      Exit(TJVMValue.Int(256));
  end;
  if (C = 'javax/microedition/lcdui/Displayable') or (C = 'javax/microedition/lcdui/Canvas') then
  begin
    if N = '<init>' then
      Exit;
    if N = 'getWidth' then
      Exit(TJVMValue.Int(FWidth));
    if N = 'getHeight' then
      Exit(TJVMValue.Int(FHeight));
    if N = 'repaint' then
    begin
      if Arg(0).AsRef <> FScreen then
        Exit;
      if (Length(Arguments) = 5) and ((Arg(3).AsInt <= 0) or (Arg(4).AsInt <= 0) or
        (Arg(1).AsInt >= FWidth) or (Arg(2).AsInt >= FHeight) or
        (Int64(Arg(1).AsInt) + Arg(3).AsInt <= 0) or (Int64(Arg(2).AsInt) + Arg(4).AsInt <= 0)) then
        Exit;
      if FExplicitInitialPaintClass <> '' then
      begin
        var Canvas := VM.GetObject(FScreen);
        if WaitingForInitialPaint(Canvas) then
          Canvas.Fields.AddOrSetValue('$canvasExplicitPaint', TJVMValue.Int(1));
      end;
      FRepaint := True;
      Exit;
    end;
    if N = '$size' then
    begin
      if Arg(0).AsRef <> FScreen then
        Exit;
      var O := VM.GetObject(Arg(0).AsRef);
      var H := FUI.ContentHeight(FScreen);
      if (LCDInt(O, 'lastWidth', -1) = FWidth) and (LCDInt(O, 'lastHeight', -1) = H) then
        Exit;
      LCDPut(O, 'lastWidth', FWidth);
      LCDPut(O, 'lastHeight', H);
      VM.InvokeGuest(VM.ResolveMethod(VM.LoadClass(O.ClassName), 'sizeChanged', '(II)V'), [Arg(0), TJVMValue.Int(FWidth), TJVMValue.Int(H)]);
      Exit;
    end;
    if N = '$pointerReady' then
      Exit(TJVMValue.Int(Ord(IsDisplayShown(Arg(0).AsRef) and FUI.IsCanvas(Arg(0).AsRef))));
    if N = '$visibility' then
    begin
      var O := VM.GetObject(Arg(0).AsRef);
      Shown := Arg(1).AsInt <> 0;
      if Shown <> IsDisplayShown(Arg(0).AsRef) then
        Exit;
      if Shown = (LCDInt(O, 'shown') <> 0) then
        Exit;
      LCDPut(O, 'shown', Ord(Shown));
      S := 'hideNotify';
      if Shown then
        S := 'showNotify';
      VM.InvokeGuest(VM.ResolveMethod(VM.LoadClass(O.ClassName), S, '()V'), [Arg(0)]);
      Exit;
    end;
    if N = '$beginPaint' then
    begin
      VM.TakeGuestResult(GuestResult);
      if not IsDisplayShown(Arg(0).AsRef) or not FRepaint then
        Exit(TJVMValue.Int(0));
      var O := VM.GetObject(Arg(0).AsRef);
      var H := FUI.ContentHeight(FScreen);
      if (LCDInt(O, 'lastWidth', -1) <> FWidth) or (LCDInt(O, 'lastHeight', -1) <> H) then
      begin
        LCDPut(O, 'lastWidth', FWidth);
        LCDPut(O, 'lastHeight', H);
        VM.InvokeGuestResult(VM.ResolveMethod(VM.LoadClass(O.ClassName), 'sizeChanged', '(II)V'), [Arg(0), TJVMValue.Int(FWidth), TJVMValue.Int(H)]);
        Exit;
      end;
      VM.GetObject(Arg(1).AsRef).Fields['$displayHeight'] := TJVMValue.Int(H);
      // Automatic requests coalesce at the virtual display cadence. Measure
      // from the start, so a slow paint does not acquire an extra idle interval.
      O.Fields.AddOrSetValue('$canvasPaintAfter', TJVMValue.Long(MonotonicMillis + 16));
      FRepaint := False;
      Exit(TJVMValue.Int(1));
    end;
    if N = '$painted' then
    begin
      if IsDisplayShown(Arg(0).AsRef) then
      begin
        if FExplicitInitialPaintClass <> '' then
        begin
          var Canvas := VM.GetObject(FScreen);
          if WaitingForInitialPaint(Canvas) then
            Canvas.Fields.AddOrSetValue('$canvasExplicitPaint', TJVMValue.Int(1));
        end;
        FHasContent := True;
        FUI.Render(FPixels, FContentPixels, MonotonicMillis);
        Inc(FFlushCount);
      end;
      Exit;
    end;
    if N = 'serviceRepaints' then
    begin
      var Screen := Arg(0).AsRef;
      if not IsDisplayShown(Screen) then
        Exit;
      var Delivery := VM.LoadClass('javax/microedition/lcdui/Canvas').FindMethod('$deliverPaint', '(Ljavax/microedition/lcdui/Graphics;)V');
      // Beginning a paint consumes the request. A different thread can still
      // be drawing that frame, including a paint that releases the monitor.
      if VM.HasOtherThreadSynchronizedCall(Delivery, Screen) then
      begin
        VM.SleepCurrent(1, '', True);
        VM.RetryNative;
        Exit;
      end;
      if FRepaint then
        VM.InvokeGuest(Delivery, [Arg(0), TJVMValue.Ref(DisplayGraphics(Screen))]);
      Exit;
    end;
    if N = 'setFullScreenMode' then
    begin
      I := FUI.ContentHeight(Arg(0).AsRef);
      LCDPut(VM.GetObject(Arg(0).AsRef), 'full', Ord(Arg(1).AsInt <> 0));
      if Arg(0).AsRef = FScreen then
      begin
        FRepaint := True;
        FUI.Invalidate;
        FLayoutHeight := FUI.ContentHeight(FScreen);
        if I <> FLayoutHeight then
          QueueUI('javax/microedition/lcdui/Canvas', '$size', '()V', [Arg(0)]);
      end;
      Exit;
    end;
    if N = 'isDoubleBuffered' then
      Exit(TJVMValue.Int(1));
    if (N = 'keyPressed') or (N = 'keyReleased') or (N = 'keyRepeated') or
      (N = 'showNotify') or (N = 'hideNotify') or (N = 'sizeChanged') or
      (N = 'pointerPressed') or (N = 'pointerReleased') or (N = 'pointerDragged') then
      Exit;
    if (N = 'hasPointerEvents') or (N = 'hasPointerMotionEvents') then
      Exit(TJVMValue.Int(1));
    if N = 'hasRepeatEvents' then
      Exit(TJVMValue.Int(0));
    if N = 'getKeyName' then
    begin
      I := J2MECanonicalKeyCode(FKeyLayout, Arg(1).AsInt);
      S := '';
      if (I >= 48) and (I <= 57) then
        S := Char(I)
      else
        case I of
          -1:
            S := 'Up';
          -2:
            S := 'Down';
          -3:
            S := 'Left';
          -4:
            S := 'Right';
          -5:
            S := 'Fire';
          -6:
            S := 'Left softkey';
          -7:
            S := 'Right softkey';
          -10:
            S := 'Send';
          -11:
            S := 'End';
          42:
            S := '*';
          35:
            S := '#';
        end;
      if S = '' then
        VM.RaiseJava('java/lang/IllegalArgumentException');
      Exit(TJVMValue.Ref(VM.NewString(S)));
    end;
    if N = 'getGameAction' then
    begin
      // The left softkey was also a select key on the Siemens SL45i.
      if (FKeyLayout = TJ2MEKeyLayout.Siemens) and (Arg(1).AsInt = -1) then
        Exit(TJVMValue.Int(8));
      I := J2MEGameAction(J2MECanonicalKeyCode(FKeyLayout, Arg(1).AsInt));
      Exit(TJVMValue.Int(I));
    end;
    if N = 'getKeyCode' then
    begin
      case Arg(1).AsInt of
        1:
          I := -1;
        6:
          I := -2;
        2:
          I := -3;
        5:
          I := -4;
        8:
          I := -5;
        9:
          I := 49;
        10:
          I := 51;
        11:
          I := 55;
        12:
          I := 57;
      else
        VM.RaiseJava('java/lang/IllegalArgumentException');
        I := 0;
      end;
      Exit(TJVMValue.Int(J2MEDeviceKeyCode(FKeyLayout, I)));
    end;
  end;
  if C = 'com/nokia/mid/ui/DirectUtils' then
    Exit(InvokeJ2MEDirectUtils(VM, Method, Arguments));
  if C = 'javax/microedition/lcdui/Graphics' then
  begin
    if (N = 'setClip') and (Arg(1).AsInt = 0) and (Arg(2).AsInt = 0) and
      (FScreen <> 0) and FUI.IsCanvas(FScreen) and
      (LCDInt(VM.GetObject(FScreen), 'full') <> 0) then
    begin
      if FViewportScreen <> FScreen then
      begin
        FViewportEvidence := Default(TJ2MEViewportEvidence);
        FViewportScreen := FScreen;
      end;
      var Graphics := VM.GetObject(Arguments[0].AsRef);
      var Translation: TJVMValue;
      var Untranslated := not Graphics.Fields.TryGetValue('$tx', Translation) or (Translation.AsInt = 0);
      Untranslated := Untranslated and (not Graphics.Fields.TryGetValue('$ty', Translation) or (Translation.AsInt = 0));
      if not Graphics.Fields.ContainsKey('$target') and Untranslated then
        FViewportEvidence.Observe(Arg(3).AsInt, Arg(4).AsInt, FWidth, FHeight);
    end;
    Exit(InvokeJ2MEGraphics(VM, Method, Arguments, FContentPixels, FWidth,
        FUI.ContentHeight(FScreen), FNativePixelFormat));
  end;
  Result := inherited;
end;

function TJ2MEHost.HasDisplayForeground(IgnoreExecutionPause: Boolean): Boolean;
begin
  Result := (FRootMIDlet <> 0) and (IgnoreExecutionPause or not FExecutionPaused) and
    not (FLifecyclePaused or FGuestPaused or FNotifyDestroyed);
end;

function TJ2MEHost.IsDisplayShown(Screen: Integer): Boolean;
begin
  Result := HasDisplayForeground and FUI.IsShown(Screen);
end;

procedure TJ2MEHost.HideCurrentCanvas;
begin
  if FUI.IsCanvas(FScreen) and (LCDInt(FVM.GetObject(FScreen), 'shown') <> 0) then
    QueueUI('javax/microedition/lcdui/Canvas', '$visibility', '(Z)V',
      [TJVMValue.Ref(FScreen), TJVMValue.Int(0)]);
end;

function TJ2MEHost.DisplayGraphics(Screen: Integer): Integer;
begin
  Result := FVM.NewObject('javax/microedition/lcdui/Graphics');
  FVM.GetObject(Result).Fields.Add('$displayHeight', TJVMValue.Int(FUI.ContentHeight(Screen)));
end;

procedure TJ2MEHost.ChangeScreen(Screen: Integer);
begin
  if (Screen <> 0) and not FUI.IsCanvas(Screen) and not FUI.IsAlert(Screen) and not FUI.IsForm(Screen) and not FUI.IsTextBox(Screen) and
    not FVM.IsAssignable(FVM.GetObject(Screen).ClassName, 'javax/microedition/lcdui/List') then
    raise EJVMUnsupported.Create('Unimplemented Displayable: ' + FVM.GetObject(Screen).ClassName);
  if Screen = FScreen then
  begin
    FRepaint := Screen <> 0;
    Exit;
  end;
  if FDisplayChanges.Count >= 1024 then
    FVM.RaiseJava('java/lang/OutOfMemoryError', 'Display request limit');
  if J2MEIsGameCanvas(FVM, Screen) then
    J2MEClearGameKeys(FVM.GetObject(Screen));
  var Change: TJ2MEDisplayChange;
  Change.Previous := FScreen;
  Change.Current := Screen;
  FVM.AddRoot(Change.Previous);
  FVM.AddRoot(Change.Current);
  FDisplayChanges.Enqueue(Change);
  FVM.AddRoot(Screen);
  FCustomKeyRepeats.Clear;
  FUI.Current(Screen);
  FVM.RemoveRoot(FScreen);
  FScreen := Screen;
  FHasContent := False;
  FLayoutHeight := FUI.ContentHeight(Screen);
  FRepaint := Screen <> 0;
  if (Screen <> 0) and FUI.IsCanvas(Screen) then
    FVM.GetObject(Screen).Fields.AddOrSetValue('$canvasPaintAfter', TJVMValue.Long(MonotonicMillis + 16));
  if Screen = 0 then
  begin
    for var I := 0 to High(FPixels) do
      FPixels[I] := $FFFFFFFF;
    Inc(FFlushCount);
  end;
end;

procedure TJ2MEHost.PostAlertTimeout(Screen, Generation: Integer);
begin
  QueueUI('javax/microedition/lcdui/Alert', '$timeout', '(I)V', [TJVMValue.Ref(Screen), TJVMValue.Int(Generation)]);
end;

procedure TJ2MEHost.QueueUI(const ClassName, Name, Descriptor: string; const Args: array of TJVMValue);
begin
  if FUIJobs.Count >= 1024 then
    FVM.RaiseJava('java/lang/OutOfMemoryError', 'UI queue limit');
  var Job: TJ2MEInvocation;
  Job.ClassName := ClassName;
  Job.Name := Name;
  Job.Descriptor := Descriptor;
  SetLength(Job.Arguments, Length(Args));
  for var I := 0 to High(Args) do
  begin
    Job.Arguments[I] := Args[I];
    if Args[I].Kind = TJVMKind.Reference then
      FVM.AddRoot(Args[I].AsRef);
  end;
  FUIJobs.Enqueue(Job);
end;

function TJ2MEHost.WaitingForInitialPaint(Canvas: TJVMObject): Boolean;
begin
  Result := not FHasContent and (Canvas.ClassName = FExplicitInitialPaintClass) and
    not Canvas.Fields.ContainsKey('$canvasExplicitPaint');
end;

function TJ2MEHost.AutomaticPaintReady: Boolean;
begin
  Result := False;
  if (FScreen = 0) or not FUI.IsCanvas(FScreen) then
    Exit;
  var O := FVM.GetObject(FScreen);
  if WaitingForInitialPaint(O) then
    Exit;
  var Deadline: TJVMValue;
  if not O.Fields.TryGetValue('$canvasPaintAfter', Deadline) then
  begin
    // Older states have no display cadence yet. Initialize a fresh interval;
    // ordinary guest fields preserve it through GC and clock-restored states.
    O.Fields.AddOrSetValue('$canvasPaintAfter', TJVMValue.Long(MonotonicMillis + 16));
    Exit;
  end;
  Result := MonotonicMillis >= Deadline.AsLong;
end;

constructor TJ2MERuntime.Create(Suite: TJ2MESuite; Width, Height: Integer; const Bluetooth: IBluetoothProvider; const Messaging: IMessagingProvider);
begin
  inherited Create;
  FQueue := TQueue<TJ2MEInvocation>.Create;
  FEventQueue := TQueue<TJ2MEInvocation>.Create;
  FHost := TJ2MEHost.Create(Suite, Width, Height, Bluetooth, Messaging);
  FVM := TJVM.Create(FHost);
  FHost.Install(FVM);
  FEventContext := FVM.CreateExecutionContext;
  FMediaContext := FVM.CreateExecutionContext;
  FRMSContext := FVM.CreateExecutionContext;
  FBluetoothContext := FVM.CreateExecutionContext;
end;

destructor TJ2MERuntime.Destroy;
begin
  ClearQueue;
  FEventQueue.Free;
  FQueue.Free;
  if FHost <> nil then
  begin
    FreeAndNil(FHost.FMessaging);
    FreeAndNil(FHost.FSiemens);
    FreeAndNil(FHost.FNokiaSound);
    FreeAndNil(FHost.FBluetoothAPI);
    FreeAndNil(FHost.FNetwork);
    FreeAndNil(FHost.FRMS);
  end;
  FVM.Free;
  FHost.Free;
  inherited;
end;

function TJ2MERuntime.GetLifecyclePauseRequested: Boolean;
begin
  Result := FHost.FLifecyclePaused;
end;

function TJ2MERuntime.GetMessagingProvider: IMessagingProvider;
begin
  Result := FHost.FMessagingProvider;
end;

function TJ2MERuntime.TakeMessagingError: string;
begin
  Result := FMessagingError;
  FMessagingError := '';
end;

function TJ2MERuntime.GetBluetoothProvider: IBluetoothProvider;
begin
  Result := FHost.FBluetooth;
end;

procedure TJ2MERuntime.Enqueue(const ClassName, Name, Descriptor: string; const Args: array of TJVMValue);
var
  Job: TJ2MEInvocation;
  I: Integer;
begin
  Job.ClassName := ClassName;
  Job.Name := Name;
  Job.Descriptor := Descriptor;
  SetLength(Job.Arguments, Length(Args));
  for I := 0 to High(Args) do
  begin
    Job.Arguments[I] := Args[I];
    if Args[I].Kind = TJVMKind.Reference then
      FVM.AddRoot(Args[I].AsRef);
  end;
  if (Name = '<init>') or (Name = 'startApp') or (Name = 'pauseApp') or (Name = 'destroyApp') then
    FQueue.Enqueue(Job)
  else
    FEventQueue.Enqueue(Job);
end;

procedure TJ2MERuntime.ClearQueue;
var
  Job: TJ2MEInvocation;
  V: TJVMValue;
begin
  if FQueue = nil then
    Exit;
  while FQueue.Count > 0 do
  begin
    Job := FQueue.Dequeue;
    for V in Job.Arguments do
      if V.Kind = TJVMKind.Reference then
        FVM.RemoveRoot(V.AsRef);
  end;
  if FEventQueue <> nil then
    while FEventQueue.Count > 0 do
    begin
      Job := FEventQueue.Dequeue;
      for V in Job.Arguments do
        if V.Kind = TJVMKind.Reference then
          FVM.RemoveRoot(V.AsRef);
    end;
  if (FHost <> nil) and (FVM <> nil) then
    while FHost.FUIJobs.Count > 0 do
    begin
      Job := FHost.FUIJobs.Dequeue;
      for V in Job.Arguments do
        if V.Kind = TJVMKind.Reference then
          FVM.RemoveRoot(V.AsRef);
    end;
  if (FHost <> nil) and (FVM <> nil) then
    while FHost.FDisplayChanges.Count > 0 do
    begin
      var Change := FHost.FDisplayChanges.Dequeue;
      FVM.RemoveRoot(Change.Previous);
      FVM.RemoveRoot(Change.Current);
    end;
end;

procedure TJ2MERuntime.Start(MIDletIndex: Integer);
begin
  if FState <> TJ2MEState.Created then
    raise EJVMError.Create('MIDlet is already started');
  FClassName := FHost.FSuite.MIDlet(MIDletIndex).ClassName;
  if not FVM.IsAssignable(FClassName, 'javax/microedition/midlet/MIDlet') then
    raise EJVMFormatError.Create('Entry class does not extend MIDlet');
  FMIDlet := FVM.NewObject(FClassName);
  FVM.AddRoot(FMIDlet);
  FState := TJ2MEState.Starting;
  FHost.FRootMIDlet := FMIDlet;
  Enqueue(FClassName, '<init>', '()V', [TJVMValue.Ref(FMIDlet)]);
  Enqueue(FClassName, 'startApp', '()V', [TJVMValue.Ref(FMIDlet)]);
end;

function IsCanvasHide(const Job: TJ2MEInvocation): Boolean;
begin
  Result := (Job.ClassName = 'javax/microedition/lcdui/Canvas') and (Job.Name = '$visibility') and
    (Length(Job.Arguments) = 2) and (Job.Arguments[1].AsInt = 0);
end;

function TJ2MERuntime.TakeDisplayEvent: TJ2MEInvocation;
begin
  var Head := FEventQueue.Peek;
  if (Head.ClassName = DisplayClass) and (Head.Name = RunFormSerially) and (Length(Head.Arguments) = 3) then
  begin
    var Screen := Head.Arguments[0].AsRef;
    if FHost.IsDisplayShown(Screen) then
    begin
      var Targets := Head.Arguments[2].AsRef;
      var Jobs := FEventQueue.ToArray;
      for var I := 1 to High(Jobs) do
      begin
        var Job := Jobs[I];
        if (Job.ClassName <> J2MECustomItemClass) or ((Job.Name <> '$measureForLayout') and (Job.Name <> '$draw')) or
          (Length(Job.Arguments) = 0) or not FHost.FUI.NeedsCapturedCustomPaint(Screen, Targets, Job.Arguments[0].AsRef) then
          Continue;
        // Layout can post paint behind a queued callback. Move only the work
        // captured by that callback, leaving the remaining events in order.
        FEventQueue.Clear;
        for var J := 0 to High(Jobs) do
          if J <> I then
            FEventQueue.Enqueue(Jobs[J]);
        Exit(Job);
      end;
    end;
  end;
  Result := FEventQueue.Dequeue;
end;

function TJ2MERuntime.HasPendingCanvasHide: Boolean;
begin
  if IsCanvasHide(FCurrentEvent) then
    Exit(True);
  for var Job in FEventQueue do
    if IsCanvasHide(Job) then
      Exit(True);
  for var Job in FHost.FUIJobs do
    if IsCanvasHide(Job) then
      Exit(True);
  Result := False;
end;

function TJ2MERuntime.TakePausedCanvasHide(out Job: TJ2MEInvocation): Boolean;
begin
  // Deliver hideNotify on the same event thread as paint, without delivering
  // the paused application's input or other deferred UI events.
  Result := False;
  for var I := 1 to FEventQueue.Count do
  begin
    var Pending := FEventQueue.Dequeue;
    if not Result and IsCanvasHide(Pending) then
    begin
      Job := Pending;
      Result := True;
    end
    else
      FEventQueue.Enqueue(Pending);
  end;
end;

function TJ2MERuntime.NeedsExecution: Boolean;
begin
  Result := False;
  if FState in [TJ2MEState.Destroyed, TJ2MEState.Faulted] then
    Exit;
  if FStopPending then
    Exit(True);
  if FHost.FExecutionPaused then
    Exit;
  if FSuspendedStartup or (FState in [TJ2MEState.Created, TJ2MEState.Destroyed, TJ2MEState.Faulted]) then
    Exit;
  if FHost.FLifecyclePaused and (FState = TJ2MEState.Paused) and (FPendingLifecycle = '') then
    Exit(HasPendingCanvasHide);
  Result := ((FState = TJ2MEState.Paused) and HasPendingCanvasHide) or FVM.HasRunnableWork or (FQueue.Count <> 0) or (FHost.FResumeRequested and not FHost.FLifecyclePaused);
  if FState <> TJ2MEState.Paused then
    Result := Result or (FEventQueue.Count <> 0) or (FHost.FUIJobs.Count <> 0) or
      (FHost.FDisplayChanges.Count <> 0) or FHost.FNokiaSound.HasEvents;
end;

procedure TJ2MERuntime.SetSensorInput(const Input: TJ2MESensorInput);
begin
  FHost.FSensors.Input := Input;
end;

function TJ2MERuntime.SensorInputRequested: Boolean;
begin
  Result := FHost.FSensors.Requested;
end;

procedure TJ2MERuntime.Tick(InstructionBudget: Integer);
var
  V: TJVMValue;
  Job: TJ2MEInvocation;
  MediaEvent: TJ2MEMediaEvent;
  StoreRef, ChangeKind, RecordID: Integer;
  MessageEvent: TJ2MEMessageEvent;
  BluetoothEvent: TJ2MEBluetoothEvent;
  NokiaSoundEvent: TNokiaSoundEvent;
begin
  if FState in [TJ2MEState.Destroyed, TJ2MEState.Faulted] then
    Exit;
  if FHost.FExecutionPaused and not FStopPending then
    Exit;
  if (FState = TJ2MEState.Created) and not FStopPending then
    Exit;
  if FSuspendedStartup and not FStopPending then
    Exit;
  try
    FHost.FNetwork.Collect;
    FHost.FMessaging.Poll;
    if FStopPending then
    begin
      FVM.Execute(1);
      FStopPending := False;
    end
    else if not FHost.FLifecyclePaused or (FState <> TJ2MEState.Paused) or (FPendingLifecycle <> '') or HasPendingCanvasHide then
      FVM.Execute(InstructionBudget);
    if FVM.ExitRequested then
    begin
      FState := TJ2MEState.Destroyed;
      FHost.FMedia.Shutdown;
      FHost.FSiemens.Shutdown;
      FHost.FEffects.Shutdown(FHost.MonotonicMillis);
      FHost.FNokiaSound.Shutdown;
      FHost.FRMS.Shutdown;
      FHost.FNetwork.Stop;
      FHost.FMessaging.Shutdown;
      FHost.FBluetoothAPI.Shutdown;
      ClearQueue;
      Exit;
    end;
    if FVM.State in [TJVMState.Faulted, TJVMState.Stopped] then
    begin
      FError := FVM.Error;
      if FError = '' then
        FError := 'JVM stopped';
      FState := TJ2MEState.Faulted;
      FHost.FMedia.Shutdown;
      FHost.FSiemens.Shutdown;
      FHost.FEffects.Shutdown(FHost.MonotonicMillis);
      FHost.FNokiaSound.Shutdown;
      FHost.FRMS.Shutdown;
      FHost.FNetwork.Stop;
      FHost.FMessaging.Shutdown;
      FHost.FBluetoothAPI.Shutdown;
      ClearQueue;
      Exit;
    end;
    if FHost.FNokiaUI.Poll(FHost.MonotonicMillis) then
    begin
      Inc(FFrameNumber);
      FFrameReady := True;
    end;
    if FHost.FMedia.UpdateVideo(FHost.FScreen) then
    begin
      if FHost.FUI.IsForm(FHost.FScreen) then
        FHost.FUI.Invalidate
      else
      begin
        Inc(FFrameNumber);
        FFrameReady := True;
      end;
    end;
    if FHost.FFlushCount <> FConsumedFlushes then
    begin
      Inc(FFrameNumber, FHost.FFlushCount - FConsumedFlushes);
      FConsumedFlushes := FHost.FFlushCount;
      FFrameReady := True;
    end;
    if (FVM.State <> TJVMState.Running) and (FCurrentCall.Name <> '') then
    begin
      if FCurrentCall.Name = 'startApp' then
      begin
        var Resuming := FState = TJ2MEState.Paused;
        FState := TJ2MEState.Active;
        if (FVM.ReturnValue.AsInt = 1) or FHost.FGuestPaused then
        begin
          FState := TJ2MEState.Paused;
          FHost.FGuestPaused := True;
          FHost.HideCurrentCanvas;
        end;
        if FVM.ReturnValue.AsInt = 2 then
        begin
          FState := TJ2MEState.Destroyed;
          FError := FHost.FLifecycleError;
        end;
        FPendingLifecycle := '';
        if Resuming and (FState = TJ2MEState.Active) and FHost.IsDisplayShown(FHost.FScreen) and
          FHost.FUI.IsCanvas(FHost.FScreen) then
        begin
          Enqueue('javax/microedition/lcdui/Canvas', '$size', '()V', [TJVMValue.Ref(FHost.FScreen)]);
          Enqueue('javax/microedition/lcdui/Canvas', '$visibility', '(Z)V', [TJVMValue.Ref(FHost.FScreen), TJVMValue.Int(1)]);
          FHost.FRepaint := True;
        end;
      end
      else if FCurrentCall.Name = 'pauseApp' then
      begin
        FState := TJ2MEState.Paused;
        FPendingLifecycle := '';
      end
      else if FCurrentCall.Name = 'destroyApp' then
      begin
        FState := TJ2MEState.Destroyed;
        FPendingLifecycle := '';
      end;
      if (FCurrentCall.Name = 'pauseApp') and (FVM.ReturnValue.AsInt = 2) then
      begin
        FState := TJ2MEState.Destroyed;
        FError := FHost.FLifecycleError;
      end;
      FCurrentCall := Default(TJ2MEInvocation);
    end;
    if FVM.ExecutionContextState(FEventContext) = TJVMState.Faulted then
    begin
      FError := FVM.ExecutionContextError(FEventContext);
      FState := TJ2MEState.Faulted;
      FHost.FMedia.Shutdown;
      FHost.FSiemens.Shutdown;
      FHost.FEffects.Shutdown(FHost.MonotonicMillis);
      FHost.FNokiaSound.Shutdown;
      FHost.FRMS.Shutdown;
      FHost.FNetwork.Stop;
      FHost.FMessaging.Shutdown;
      FHost.FBluetoothAPI.Shutdown;
      ClearQueue;
      Exit;
    end;
    if (FVM.ExecutionContextState(FEventContext) <> TJVMState.Running) and (FCurrentEvent.Name <> '') then
    begin
      FCurrentEvent := Default(TJ2MEInvocation);
    end;
    if FHost.FNotifyDestroyed then
      FState := TJ2MEState.Destroyed
    else if FHost.FNotifyPaused then
    begin
      FHost.FNotifyPaused := False;
      FState := TJ2MEState.Paused;
    end;
    if FState = TJ2MEState.Destroyed then
    begin
      FHost.FMedia.Shutdown;
      FHost.FSiemens.Shutdown;
      FHost.FEffects.Shutdown(FHost.MonotonicMillis);
      FHost.FNokiaSound.Shutdown;
      FHost.FRMS.Shutdown;
      FHost.FNetwork.Stop;
      FHost.FMessaging.Shutdown;
      FHost.FBluetoothAPI.Shutdown;
      ClearQueue;
      Exit;
    end;
    if FHost.FResumeRequested and not FHost.FLifecyclePaused and (FState = TJ2MEState.Paused) and (FPendingLifecycle = '') and (FCurrentCall.Name = '') then
    begin
      FHost.FResumeRequested := False;
      Resume;
    end;
    if FMessagingCallRunning and (FVM.ExecutionContextState(FMessagingContext) <> TJVMState.Running) then
    begin
      if FVM.ExecutionContextState(FMessagingContext) = TJVMState.Faulted then
        FMessagingError := Copy(FVM.ExecutionContextError(FMessagingContext), 1, 4096);
      FMessagingCallRunning := False;
    end;
    if not FHost.FLifecyclePaused and not FMessagingCallRunning and FHost.FMessaging.TakeEvent(MessageEvent) then
    begin
      try
        if FMessagingContext = 0 then
          FMessagingContext := FVM.CreateExecutionContext;
        FHost.FMessaging.BeginEvent(FMessagingContext, MessageEvent);
        FMessagingCallRunning := True;
      finally
        FHost.FMessaging.ReleaseEvent(MessageEvent);
      end;
    end;
    if FBluetoothCallRunning and (FVM.ExecutionContextState(FBluetoothContext) <> TJVMState.Running) then
    begin
      if FVM.ExecutionContextState(FBluetoothContext) = TJVMState.Faulted then
        FBluetoothError := FVM.ExecutionContextError(FBluetoothContext);
      FBluetoothCallRunning := False;
    end;
    if FState <> TJ2MEState.Paused then
    begin
      FHost.FBluetoothAPI.Poll;
      if not FBluetoothCallRunning and FHost.FBluetoothAPI.TakeEvent(BluetoothEvent) then
      begin
        try
          FVM.BeginContextCall(FBluetoothContext, 'javax/bluetooth/DiscoveryAgent$Dispatcher', BluetoothEvent.Name, BluetoothEvent.Descriptor, BluetoothEvent.Arguments);
          FBluetoothCallRunning := True;
        finally
          FHost.FBluetoothAPI.ReleaseEvent(BluetoothEvent);
        end;
      end;
    end;
    if FMediaCallRunning and (FVM.ExecutionContextState(FMediaContext) <> TJVMState.Running) then
    begin
      if FVM.ExecutionContextState(FMediaContext) = TJVMState.Faulted then
        FMediaError := FVM.ExecutionContextError(FMediaContext);
      FMediaCallRunning := False;
    end;
    if (FState <> TJ2MEState.Paused) and not FMediaCallRunning and FHost.FNokiaSound.TakeEvent(NokiaSoundEvent) then
    begin
      try
        FVM.BeginContextCall(FMediaContext, FVM.GetObject(NokiaSoundEvent.Listener).ClassName, 'soundStateChanged',
          '(Lcom/nokia/mid/sound/Sound;I)V', [TJVMValue.Ref(NokiaSoundEvent.Listener), TJVMValue.Ref(NokiaSoundEvent.Sound), TJVMValue.Int(NokiaSoundEvent.State)]);
        FMediaCallRunning := True;
      finally
        FHost.FNokiaSound.ReleaseEvent(NokiaSoundEvent);
      end;
    end;
    if (FState <> TJ2MEState.Paused) and not FMediaCallRunning and FHost.FMedia.TakeEvent(MediaEvent) then
    begin
      try
        FVM.BeginContextCall(FMediaContext, FVM.GetObject(MediaEvent.Listener).ClassName, 'playerUpdate',
          FHost.FMedia.PlayerUpdateDescriptor(MediaEvent.Player),
          [TJVMValue.Ref(MediaEvent.Listener), TJVMValue.Ref(MediaEvent.Player), TJVMValue.Ref(MediaEvent.EventName), TJVMValue.Ref(MediaEvent.Data)]);
        FMediaCallRunning := True;
      finally
        FHost.FMedia.ReleaseEvent(MediaEvent);
      end;
    end;
    if FRMSCallRunning and (FVM.ExecutionContextState(FRMSContext) <> TJVMState.Running) then
    begin
      if FVM.ExecutionContextState(FRMSContext) = TJVMState.Faulted then
        FRMSError := FVM.ExecutionContextError(FRMSContext);
      FRMSCallRunning := False;
    end;
    if (FState <> TJ2MEState.Paused) and not FRMSCallRunning and FHost.FRMS.TakeNotification(StoreRef, ChangeKind, RecordID) then
    begin
      FVM.BeginContextCall(FRMSContext, 'javax/microedition/rms/RecordStore', '$notifyPending', '(II)V',
        [TJVMValue.Ref(StoreRef), TJVMValue.Int(ChangeKind), TJVMValue.Int(RecordID)]);
      FRMSCallRunning := True;
    end;
    FHost.FUI.PauseTimer((FState = TJ2MEState.Paused) or (FPendingLifecycle = 'pauseApp'), FHost.MonotonicMillis);
    while FHost.FDisplayChanges.Count > 0 do
    begin
      var Change := FHost.FDisplayChanges.Dequeue;
      try
        if (FPointerScreen <> 0) and (Change.Previous = FPointerScreen) then
          CancelPointer;
        if FHost.FUI.IsCanvas(Change.Previous) then
          Enqueue('javax/microedition/lcdui/Canvas', '$visibility', '(Z)V', [TJVMValue.Ref(Change.Previous), TJVMValue.Int(0)]);
        if Change.Current <> 0 then
        begin
          if FHost.FUI.IsCanvas(Change.Current) then
          begin
            if FHost.HasDisplayForeground then
              Enqueue('javax/microedition/lcdui/Canvas', '$size', '()V', [TJVMValue.Ref(Change.Current)]);
            if FHost.IsDisplayShown(Change.Current) then
              Enqueue('javax/microedition/lcdui/Canvas', '$visibility', '(Z)V', [TJVMValue.Ref(Change.Current), TJVMValue.Int(1)]);
          end
          else
            Enqueue(FVM.GetObject(Change.Current).ClassName, 'sizeChanged', '(II)V', [TJVMValue.Ref(Change.Current), TJVMValue.Int(FHost.FUI.ContentWidth(Change.Current)), TJVMValue.Int(FHost.FUI.ContentHeight(Change.Current))]);
        end;
      finally
        FVM.RemoveRoot(Change.Previous);
        FVM.RemoveRoot(Change.Current);
      end;
    end;
    if (FHost.FScreen <> 0) and (FHost.FHasContent or not FHost.FUI.IsCanvas(FHost.FScreen)) and FHost.FUI.NeedsRender(FHost.MonotonicMillis) then
    begin
      FHost.FUI.Render(FHost.FPixels, FHost.FContentPixels, FHost.MonotonicMillis);
      Inc(FFrameNumber);
      FFrameReady := True;
    end;
    while FHost.FUIJobs.Count > 0 do
    begin
      Job := FHost.FUIJobs.Dequeue;
      try
        Enqueue(Job.ClassName, Job.Name, Job.Descriptor, Job.Arguments);
      finally
        for V in Job.Arguments do
          if V.Kind = TJVMKind.Reference then
            FVM.RemoveRoot(V.AsRef);
      end;
    end;
    if FState in [TJ2MEState.Starting, TJ2MEState.Active] then
      FHost.FUI.PollAlert(FHost.MonotonicMillis);
    if (FEventQueue.Count = 0) and (FVM.ExecutionContextState(FEventContext) <> TJVMState.Running) and
      (FState in [TJ2MEState.Starting, TJ2MEState.Active]) and FHost.FRepaint and FHost.IsDisplayShown(FHost.FScreen) and FHost.AutomaticPaintReady then
    begin
      Enqueue('javax/microedition/lcdui/Canvas', '$deliverPaint', '(Ljavax/microedition/lcdui/Graphics;)V',
        [TJVMValue.Ref(FHost.FScreen), TJVMValue.Ref(FHost.DisplayGraphics(FHost.FScreen))]);
    end;
    if (FVM.State <> TJVMState.Running) and (FQueue.Count > 0) then
    begin
      Job := FQueue.Dequeue;
      try
        if (Job.Name = 'startApp') or (Job.Name = 'pauseApp') or (Job.Name = 'destroyApp') then
        begin
          if Job.Name = 'startApp' then
          begin
            FHost.FMIDletStarted := True;
            FHost.FGuestPaused := False;
            FHost.FResumeRequested := False;
          end
          else if Job.Name = 'pauseApp' then
            FHost.FGuestPaused := True;
          var Desc := '(Ljavax/microedition/midlet/MIDlet;)I';
          if Job.Name = 'destroyApp' then
            Desc := '(Ljavax/microedition/midlet/MIDlet;Z)I';
          FVM.BeginCall('javax/microedition/midlet/MIDlet$Lifecycle', Job.Name, Desc, Job.Arguments);
        end
        else
          FVM.BeginCall(Job.ClassName, Job.Name, Job.Descriptor, Job.Arguments);
        FCurrentCall := Job;
      finally
        for V in Job.Arguments do
          if V.Kind = TJVMKind.Reference then
            FVM.RemoveRoot(V.AsRef);
      end;
    end;
    PollCustomKeyRepeats;
    if (FState = TJ2MEState.Active) and FHost.HasDisplayForeground then
    begin
      var SensorArgs: TArray<TJVMValue>;
      var CanDeliver := (FEventQueue.Count = 0) and (FVM.ExecutionContextState(FEventContext) <> TJVMState.Running);
      if FHost.FSensors.Poll(FMIDlet, FHost.MonotonicMillis, CanDeliver, SensorArgs) then
        Enqueue(J2MESensorConnection, '$deliver', J2MESensorDelivery, SensorArgs);
    end;
    if (FVM.ExecutionContextState(FEventContext) <> TJVMState.Running) and (FEventQueue.Count > 0) then
    begin
      if FHost.HasDisplayForeground then
        Job := TakeDisplayEvent
      else if not TakePausedCanvasHide(Job) then
        Exit;
      try
        FVM.BeginContextCall(FEventContext, Job.ClassName, Job.Name, Job.Descriptor, Job.Arguments);
        FCurrentEvent := Job;
      finally
        for V in Job.Arguments do
          if V.Kind = TJVMKind.Reference then
            FVM.RemoveRoot(V.AsRef);
      end;
    end;
  except
    on E: Exception do
    begin
      FError := E.ClassName + ': ' + E.Message;
      FState := TJ2MEState.Faulted;
      FHost.FMedia.Shutdown;
      FHost.FSiemens.Shutdown;
      FHost.FEffects.Shutdown(FHost.MonotonicMillis);
      FHost.FNokiaSound.Shutdown;
      FHost.FRMS.Shutdown;
      FHost.FNetwork.Stop;
      FHost.FMessaging.Shutdown;
      FHost.FBluetoothAPI.Shutdown;
      ClearQueue;
    end;
  end;
end;

procedure TJ2MERuntime.SetExecutionPaused(Value: Boolean);
begin
  if Value = FHost.FExecutionPaused then
    Exit;
  if Value then
  begin
    ReleasePhysicalKeys;
    CancelVibration;
    FHost.FExecutionWall := FHost.TimeMillis;
    FHost.FExecutionMono := FHost.MonotonicMillis;
    FHost.FExecutionPaused := True;
  end
  else
  begin
    FHost.FExecutionPaused := False;
    Inc(FHost.FWallOffset, FHost.FExecutionWall - FHost.TimeMillis);
    Inc(FHost.FMonotonicOffset, FHost.FExecutionMono - FHost.MonotonicMillis);
  end;
end;

procedure TJ2MERuntime.Pause;
begin
  FHost.FLifecyclePaused := True;
  FHost.FCustomKeyRepeats.Clear;
  CancelVibration;
  // Some older games keep startApp alive for their entire session. Emulation
  // pause must still freeze them, without queuing a second lifecycle callback.
  if FState = TJ2MEState.Starting then
  begin
    if FHost.FScreen <> 0 then
      J2MEClearGameKeys(FVM.GetObject(FHost.FScreen));
    FHost.FPhysicalKeys.Clear;
    FHost.FUI.PauseTimer(True, FHost.MonotonicMillis);
    FSuspendedStartup := True;
    FState := TJ2MEState.Paused;
    Exit;
  end;
  if (FState = TJ2MEState.Active) and (FPendingLifecycle = '') then
  begin
    FHost.HideCurrentCanvas;
    if FHost.FScreen <> 0 then
      J2MEClearGameKeys(FVM.GetObject(FHost.FScreen));
    FHost.FPhysicalKeys.Clear;
    FHost.FUI.PauseTimer(True, FHost.MonotonicMillis);
    FPendingLifecycle := 'pauseApp';
    Enqueue(FClassName, 'pauseApp', '()V', [TJVMValue.Ref(FMIDlet)]);
  end;
end;

procedure TJ2MERuntime.Resume;
begin
  FHost.FLifecyclePaused := False;
  if FSuspendedStartup then
  begin
    FHost.FUI.PauseTimer(False, FHost.MonotonicMillis);
    FSuspendedStartup := False;
    FState := TJ2MEState.Starting;
    Exit;
  end;
  if (FState = TJ2MEState.Paused) and (FPendingLifecycle = '') then
  begin
    FHost.FResumeRequested := False;
    FPendingLifecycle := 'startApp';
    Enqueue(FClassName, 'startApp', '()V', [TJVMValue.Ref(FMIDlet)]);
  end
  else if FPendingLifecycle = 'pauseApp' then
    FHost.FResumeRequested := True;
end;

procedure TJ2MERuntime.DestroyApp;
begin
  if FState in [TJ2MEState.Destroyed, TJ2MEState.Faulted, TJ2MEState.Created] then
    Exit;
  SetExecutionPaused(False);
  FSuspendedStartup := False;
  FHost.FCustomKeyRepeats.Clear;
  ClearQueue;
  FPendingLifecycle := 'destroyApp';
  Enqueue(FClassName, 'destroyApp', '(Z)V', [TJVMValue.Ref(FMIDlet), TJVMValue.Int(1)]);
end;

procedure TJ2MERuntime.CoalesceKeyEvents;
begin
  var Jobs := FEventQueue.ToArray;
  var Latest := TDictionary<string, Integer>.Create;
  try
    for var I := 0 to High(Jobs) do
      if (Jobs[I].Name = '$key') and (Length(Jobs[I].Arguments) = 3) then
        Latest.AddOrSetValue(IntToStr(Jobs[I].Arguments[0].AsRef) + ':' + IntToStr(Jobs[I].Arguments[1].AsInt), I);
    FEventQueue.Clear;
    for var I := 0 to High(Jobs) do
    begin
      var Keep := True;
      if (Jobs[I].Name = '$key') and (Length(Jobs[I].Arguments) = 3) then
        Keep := Latest[IntToStr(Jobs[I].Arguments[0].AsRef) + ':' + IntToStr(Jobs[I].Arguments[1].AsInt)] = I;
      if Keep then
        FEventQueue.Enqueue(Jobs[I])
      else
        for var V in Jobs[I].Arguments do
          if V.Kind = TJVMKind.Reference then
            FVM.RemoveRoot(V.AsRef);
    end;
  finally
    Latest.Free;
  end;
end;

procedure TJ2MERuntime.KeyEvent(KeyCode: Integer; Pressed: Boolean);
begin
  if not FHost.FExecutionPaused then
    ApplyKeyEvent(KeyCode, Pressed);
end;

function TJ2MEHost.CustomKeyRepeatIndex(Code: Integer): Integer;
begin
  for var I := 0 to FCustomKeyRepeats.Count - 1 do
    if FCustomKeyRepeats[I].Code = Code then
      Exit(I);
  Result := -1;
end;

procedure TJ2MERuntime.PollCustomKeyRepeats;
begin
  var Repeats := FHost.FCustomKeyRepeats;
  if (Repeats.Count = 0) or FHost.FLifecyclePaused or (FPendingLifecycle = 'destroyApp') or
    not (FState in [TJ2MEState.Active, TJ2MEState.Starting]) then
    Exit;
  for var I := Repeats.Count - 1 downto 0 do
  begin
    var Held := Repeats[I];
    if not FHost.FPhysicalKeys.ContainsKey(Held.Code) or
      (FHost.FUI.CustomKeyTarget(FHost.FScreen, Held.Code) <> Held.Item) then
      Repeats.Delete(I);
  end;
  if (Repeats.Count = 0) or (FEventQueue.Count <> 0) or (FHost.FUIJobs.Count <> 0) or
    (FVM.ExecutionContextState(FEventContext) = TJVMState.Running) then
    Exit;
  var Index := 0;
  for var I := 1 to Repeats.Count - 1 do
    if Repeats[I].Next < Repeats[Index].Next then
      Index := I;
  var Held := Repeats[Index];
  var Now := FHost.MonotonicMillis;
  if Now < Held.Next then
    Exit;
  // Leave missed repeats behind when guest callbacks hold up the event queue.
  Held.Next := Now + CustomKeyRepeatIntervalMS;
  Repeats[Index] := Held;
  Enqueue(J2MECustomItemClass, '$repeatKey', '(I)V', [TJVMValue.Ref(Held.Item), TJVMValue.Int(Held.Code)]);
end;

procedure TJ2MERuntime.ApplyKeyEvent(KeyCode: Integer; Pressed: Boolean; IgnoreExecutionPause: Boolean);
var
  FreshPress: Boolean;
begin
  if not Pressed then
  begin
    var Index := FHost.CustomKeyRepeatIndex(KeyCode);
    if Index >= 0 then
      FHost.FCustomKeyRepeats.Delete(Index);
  end;
  if not FHost.HasDisplayForeground(IgnoreExecutionPause) or not (FState in [TJ2MEState.Active, TJ2MEState.Starting]) or
    (FHost.FScreen = 0) then
    Exit;
  // Host key sources use a finite phone alphabet. Bound even a malformed
  // producer sending arbitrary distinct integers, without losing known releases.
  if not FHost.FKnownPhysicalKeys.ContainsKey(KeyCode) then
  begin
    if FHost.FKnownPhysicalKeys.Count >= 256 then
      Exit;
    FHost.FKnownPhysicalKeys.Add(KeyCode, True);
  end;
  FreshPress := Pressed and not FHost.FPhysicalKeys.ContainsKey(KeyCode);
  if Pressed then
    FHost.FPhysicalKeys.AddOrSetValue(KeyCode, True)
  else
    FHost.FPhysicalKeys.Remove(KeyCode);
  if J2MEIsGameCanvas(FVM, FHost.FScreen) then
  begin
    if FHost.FUI.IsShown(FHost.FScreen) then
    begin
      if J2MEGameKeyEvent(FVM.GetObject(FHost.FScreen), KeyCode, Pressed, FreshPress) then
        Exit;
    end
    else
      J2MEClearGameKeys(FVM.GetObject(FHost.FScreen));
  end;
  if Pressed and not FreshPress then
    Exit;
  // Normal input preserves every transition. On a burst retain the latest
  // transition for each screen/key, including releases, rather than faulting.
  if FEventQueue.Count >= 256 then
    CoalesceKeyEvents;
  Enqueue('javax/microedition/lcdui/Displayable', '$key', '(IZ)V',
    [TJVMValue.Ref(FHost.FScreen), TJVMValue.Int(KeyCode), TJVMValue.Int(Ord(Pressed))]);
end;

function TJ2MERuntime.HasTouchCanvas: Boolean;
begin
  Result := (FHost.FScreen <> 0) and FHost.FUI.IsCanvas(FHost.FScreen) and
    FHost.FUI.IsShown(FHost.FScreen);
end;

function TJ2MERuntime.HasTouchInput: Boolean;
begin
  Result := HasTouchCanvas or FHost.FUI.HasCustomPointerInput;
end;

procedure TJ2MERuntime.CancelPointer;
begin
  FHost.FUI.CancelCustomPointer;
  var Screen := FPointerScreen;
  if (Screen = 0) and HasTouchCanvas and
    (LCDInt(FVM.GetObject(FHost.FScreen), 'pointerHeld') <> 0) then
    Screen := FHost.FScreen;
  if Screen = 0 then
    Exit;
  LCDPut(FVM.GetObject(Screen), 'pointerHeld', 0);
  // MIDP has no pointerCancelled callback. Release outside the picture so a
  // focus loss ends the gesture without selecting the item under the pointer.
  Enqueue('javax/microedition/lcdui/Canvas', '$deliverPointer', '(III)V',
    [TJVMValue.Ref(Screen), TJVMValue.Int(2), TJVMValue.Int(-1), TJVMValue.Int(-1)]);
  FPointerScreen := 0;
end;

procedure TJ2MERuntime.PointerEvent(const Event: TEmulationTouchEvent);
begin
  if Event.Contact <> 0 then
    Exit; // MIDP exposes one primary pointer.
  if Event.Phase = TEmulationTouchPhase.Cancel then
  begin
    CancelPointer;
    Exit;
  end;
  if FHost.FExecutionPaused or FHost.FLifecyclePaused or
    not (FState in [TJ2MEState.Active, TJ2MEState.Starting]) then
  begin
    CancelPointer;
    Exit;
  end;
  if FHost.FUI.IsForm(FHost.FScreen) then
  begin
    var Queued := FEventQueue.Count + FHost.FUIJobs.Count;
    if ((Event.Phase = TEmulationTouchPhase.Move) and (Queued >= 128)) or
      ((Event.Phase = TEmulationTouchPhase.Down) and (Queued >= 240)) then
      Exit;
    FHost.FUI.CustomPointer(Event);
    Exit;
  end;
  if not HasTouchCanvas then
  begin
    CancelPointer;
    Exit;
  end;
  if (FPointerScreen <> 0) and (FPointerScreen <> FHost.FScreen) then
    CancelPointer;
  var X := Event.X;
  var Y := Event.Y - FHost.FUI.Top(FHost.FScreen);
  if (X < 0) or (Y < 0) or (X >= FHost.FWidth) or (Y >= FHost.FUI.ContentHeight(FHost.FScreen)) then
  begin
    CancelPointer;
    Exit;
  end;
  if Event.Phase = TEmulationTouchPhase.Down then
  begin
    if (FPointerScreen <> 0) or (FEventQueue.Count >= 240) then
      Exit;
    FPointerScreen := FHost.FScreen;
    LCDPut(FVM.GetObject(FPointerScreen), 'pointerHeld', 1);
  end
  else if FPointerScreen = 0 then
    Exit;
  if (Event.Phase = TEmulationTouchPhase.Move) and (FEventQueue.Count >= 128) then
    Exit;
  var Phase := Ord(Event.Phase);
  Enqueue('javax/microedition/lcdui/Canvas', '$deliverPointer', '(III)V',
    [TJVMValue.Ref(FPointerScreen), TJVMValue.Int(Phase), TJVMValue.Int(X), TJVMValue.Int(Y)]);
  if Event.Phase = TEmulationTouchPhase.Up then
  begin
    LCDPut(FVM.GetObject(FPointerScreen), 'pointerHeld', 0);
    FPointerScreen := 0;
  end;
end;

procedure TJ2MERuntime.TextInput(const Text: string);
begin
  if FHost.FExecutionPaused or not (FState in [TJ2MEState.Active, TJ2MEState.Starting]) or (FHost.FScreen = 0) or (Text = '') then
    Exit;
  if Length(Text) > FVM.MaxArrayLength then
    raise EArgumentOutOfRangeException.Create('Text input size');
  if FEventQueue.Count >= 256 then
    raise EJVMError.Create('MIDlet input queue overflow');
  var Ref := FVM.NewString(Text);
  Enqueue('javax/microedition/lcdui/Displayable', '$text', '(Ljava/lang/String;)V', [TJVMValue.Ref(FHost.FScreen), TJVMValue.Ref(Ref)]);
end;

procedure TJ2MERuntime.RequestStop;
begin
  FStopPending := True;
  FVM.RequestStop;
end;

procedure TJ2MERuntime.CancelVibration;
begin
  FHost.FEffects.SetVibration(0, 0, FHost.MonotonicMillis);
  FHost.FEffects.TakeVibration(FHost.MonotonicMillis);
end;

function TJ2MERuntime.TakeVibrationSample: TJ2MEVibrationSample;
begin
  if FHost.FExecutionPaused or FHost.FLifecyclePaused or (FState in [TJ2MEState.Paused, TJ2MEState.Destroyed, TJ2MEState.Faulted]) then
  begin
    CancelVibration;
    Exit(Default(TJ2MEVibrationSample));
  end;
  Result := FHost.FEffects.TakeVibration(FHost.MonotonicMillis);
  if FHost.FMedia.VibrationActive then
    Result.Area := Result.Millis * 100.0;
end;

function TJ2MERuntime.TakeLifecycleError: string;
begin
  Result := FHost.FLifecycleError;
  FHost.FLifecycleError := '';
end;

function TJ2MERuntime.TakeFrame(out Pixels: TArray<UInt32>; out Number: UInt64): Boolean;
begin
  Result := FFrameReady;
  if not Result then
    Exit;
  FHost.FViewportEvidence.CompleteFrame;
  Pixels := Copy(FHost.FPixels);
  FHost.FMedia.DrawVideo(FHost.FScreen, Pixels, FHost.FWidth, FHost.FHeight);
  FHost.FNokiaUI.ApplyBacklight(Pixels);
  Number := FFrameNumber;
  FFrameReady := False;
end;

function TJ2MERuntime.IsFullscreenCanvas: Boolean;
begin
  Result := (FHost.FScreen <> 0) and FHost.FUI.IsCanvas(FHost.FScreen) and
    (LCDInt(FVM.GetObject(FHost.FScreen), 'full') <> 0);
end;

function TJ2MERuntime.RenderAudio(Frames: Integer): TArray<SmallInt>;
begin
  if (Frames < 0) or (Frames > 8192) then
    raise EArgumentOutOfRangeException.Create('Media render block');
  if FHost.FExecutionPaused or (FState in [TJ2MEState.Created, TJ2MEState.Paused, TJ2MEState.Destroyed, TJ2MEState.Faulted]) then
  begin
    Result := nil;
    SetLength(Result, Frames * 2);
    Exit;
  end;
  FHost.FMedia.RenderMixInto(FMixBuffer, Frames);
  var Mix := FMixBuffer;
  FHost.FNokiaSound.MixInto(Mix, Frames);
  FHost.FSiemens.MixInto(Mix, Frames);
  SetLength(Result, Length(Mix));
  for var I := 0 to High(Result) do
    Result[I] := SmallInt(System.Math.EnsureRange(Mix[I], Int64(-32768), Int64(32767)));
end;

function TJ2MERuntime.TakeMediaError: string;
begin
  Result := FMediaError;
  FMediaError := '';
end;

function TJ2MERuntime.TakeBluetoothError: string;
begin
  Result := FBluetoothError;
  FBluetoothError := '';
end;

function TJ2MERuntime.TakeRMSError: string;
begin
  Result := FRMSError;
  FRMSError := '';
end;

procedure TransferJ2MEInvocation(S: TJVMStateIO; var Call: TJ2MEInvocation);
begin
  S.Text(Call.ClassName);
  S.Text(Call.Name);
  S.Text(Call.Descriptor);
  S.Values(Call.Arguments);
end;

procedure TransferJ2MEQueue(S: TJVMStateIO; Queue: TQueue<TJ2MEInvocation>);
begin
  var Items := Queue.ToArray;
  var N: Integer := Length(Items);
  S.Count(N, 65536);
  if S.Loading then
  begin
    Queue.Clear;
    SetLength(Items, N);
  end;
  for var I := 0 to N - 1 do
  begin
    TransferJ2MEInvocation(S, Items[I]);
    if S.Loading then
      Queue.Enqueue(Items[I]);
  end;
end;

procedure TJ2MERuntime.TransferState(S: TJVMStateIO);
begin
  FVM.TransferState(S);
  var State: Integer := Ord(FState);
  S.Count(State, Ord(High(TJ2MEState)));
  FState := TJ2MEState(State);
  S.Int(FMIDlet);
  S.Text(FClassName);
  S.Text(FError);
  S.Text(FPendingLifecycle);
  TransferJ2MEQueue(S, FQueue);
  TransferJ2MEQueue(S, FEventQueue);
  TransferJ2MEInvocation(S, FCurrentCall);
  TransferJ2MEInvocation(S, FCurrentEvent);
  S.Int(FEventContext);
  S.UInt64Value(FFrameNumber);
  S.UInt64Value(FConsumedFlushes);
  S.Bool(FFrameReady);
  S.Bool(FSuspendedStartup);
  S.Bool(FHost.FLifecyclePaused);
  S.Bool(FStopPending);
  S.Int(FMediaContext);
  S.Bool(FMediaCallRunning);
  S.Text(FMediaError);
  S.Text(FRMSError);
  S.Int(FRMSContext);
  S.Bool(FRMSCallRunning);
  S.Int(FBluetoothContext);
  S.Bool(FBluetoothCallRunning);
  S.Text(FBluetoothError);
  S.Int(FMessagingContext);
  S.Bool(FMessagingCallRunning);
  S.Text(FMessagingError);
  S.Int(FHost.FDisplay);
  S.Int(FHost.FScreen);
  S.Pixels(FHost.FPixels);
  S.Pixels(FHost.FContentPixels);
  S.Bool(FHost.FRepaint);
  S.Bool(FHost.FNotifyDestroyed);
  S.Bool(FHost.FNotifyPaused);
  S.Bool(FHost.FHasContent);
  S.Int(FHost.FRootMIDlet);
  S.Bool(FHost.FMIDletStarted);
  S.Bool(FHost.FGuestPaused);
  S.Bool(FHost.FResumeRequested);
  S.Text(FHost.FLifecycleError);
  S.UInt64Value(FHost.FFlushCount);
  S.Int(FHost.FLayoutHeight);
  var Keys := FHost.FPhysicalKeys.Keys.ToArray;
  var N: Integer := Length(Keys);
  S.Count(N, 1024);
  if S.Loading then
    FHost.FPhysicalKeys.Clear
  else
    TArray.Sort<Integer>(Keys);
  for var I := 0 to N - 1 do
  begin
    var Key := 0;
    var Pressed := False;
    if not S.Loading then
    begin
      Key := Keys[I];
      Pressed := FHost.FPhysicalKeys[Key];
    end;
    S.Int(Key);
    S.Bool(Pressed);
    if S.Loading then
      FHost.FPhysicalKeys.Add(Key, Pressed);
  end;
  var Changes := FHost.FDisplayChanges.ToArray;
  N := Length(Changes);
  S.Count(N, 65536);
  if S.Loading then
  begin
    FHost.FDisplayChanges.Clear;
    SetLength(Changes, N);
  end;
  for var I := 0 to N - 1 do
  begin
    S.Int(Changes[I].Previous);
    S.Int(Changes[I].Current);
    if S.Loading then
      FHost.FDisplayChanges.Enqueue(Changes[I]);
  end;
  TransferJ2MEQueue(S, FHost.FUIJobs);
  FHost.FUI.TransferState(S);
  FHost.FEffects.TransferState(S);
  FHost.FMedia.TransferState(S);
  FHost.FNokiaSound.TransferState(S);
  FHost.FSiemens.TransferState(S);
  FHost.FRMS.TransferState(S);
  S.Tag('end-J2ME-1');
  if S.Loading then
  begin
    if S.HasRemaining then
      FHost.FBluetoothAPI.TransferSnapshotData(S);
  end
  else if FHost.FBluetoothAPI.HasSnapshotData then
    FHost.FBluetoothAPI.TransferSnapshotData(S);
  if S.Loading then
  begin
    if (Length(FHost.FPixels) <> FHost.FWidth * FHost.FHeight) or (Length(FHost.FContentPixels) <> Length(FHost.FPixels)) then
      raise EReadError.Create('Invalid snapshot screen pixels');
    FFrameReady := True;
    if FHost.FLifecyclePaused or FHost.FGuestPaused then
      FHost.HideCurrentCanvas;
  end;
end;

procedure TJ2MERuntime.SaveState(Stream: TStream);
begin
  FHost.FNetwork.RequireSnapshotIdle;
  FHost.FBluetoothAPI.RequireSnapshotIdle;
  FHost.FMessaging.RequireSnapshotIdle;
  var S := TJVMStateIO.Create(Stream, False);
  try
    S.Tag('RetroMul-J2ME-1');
    var Width := FHost.FWidth;
    var Height := FHost.FHeight;
    S.Int(Width);
    S.Int(Height);
    var Wall := FHost.TimeMillis;
    var Mono := FHost.MonotonicMillis;
    S.Int64Value(Wall);
    S.Int64Value(Mono);
    TransferState(S);
  finally
    S.Free;
  end;
end;

class function TJ2MERuntime.LoadState(Suite: TJ2MESuite; Stream: TStream; const Bluetooth: IBluetoothProvider; const Messaging: IMessagingProvider; StartPaused: Boolean): TJ2MERuntime;
begin
  Result := nil;
  var S := TJVMStateIO.Create(Stream, True);
  try
    S.Tag('RetroMul-J2ME-1');
    var Width := 0;
    var Height := 0;
    S.Int(Width);
    S.Int(Height);
    var Wall := Int64(0);
    var Mono := Int64(0);
    S.Int64Value(Wall);
    S.Int64Value(Mono);
    Result := TJ2MERuntime.Create(Suite, Width, Height, Bluetooth, Messaging);
    try
      // Restore timers and UI deadlines against the saved clocks. Reading
      // and validating the state is host work, outside the guest timeline.
      Result.FHost.FExecutionWall := Wall;
      Result.FHost.FExecutionMono := Mono;
      Result.FHost.FExecutionPaused := True;
      Result.TransferState(S);
      S.Finish;
      Result.FRestoredState := True;
      if not StartPaused then
        Result.SetExecutionPaused(False);
    except
      FreeAndNil(Result);
      raise;
    end;
  finally
    S.Free;
  end;
end;

procedure TJ2MERuntime.CommitRestoredState;
begin
  FHost.FRMS.ApplyRestoredState;
end;

procedure TJ2MERuntime.ReleasePhysicalKeys;
begin
  FHost.FCustomKeyRepeats.Clear;
  CancelPointer;
  var Keys := FHost.FPhysicalKeys.Keys.ToArray;
  // A loaded VM is often host-paused. Clear its held state now and let the
  // release callbacks run when guest execution resumes.
  for var Key in Keys do
    ApplyKeyEvent(Key, False, True);
  FHost.FPhysicalKeys.Clear;
end;

procedure TJ2MERuntime.ReconcilePhysicalKeys(const DesiredKeys: TArray<Integer>);

  function StillHeld(Code: Integer): Boolean;
  begin
    for var Key in DesiredKeys do
      if Key = Code then
        Exit(True);
    Result := False;
  end;

begin
  // Overflow supplies a snapshot of the host key state. Preserve keys that
  // are already down, along with their repeats and any independent pointer.
  var CurrentKeys := FHost.FPhysicalKeys.Keys.ToArray;
  for var Key in CurrentKeys do
    if not StillHeld(Key) then
      KeyEvent(Key, False);
  for var Key in DesiredKeys do
    if not FHost.FPhysicalKeys.ContainsKey(Key) then
      KeyEvent(Key, True);
end;

function TJ2MERuntime.ScreenRecommendation(out Size: TJ2MEScreenSize): Boolean;
begin
  Size := Default(TJ2MEScreenSize);
  Result := not FRestoredState and FHost.FViewportEvidence.Recommendation(Size);
end;

function TJ2MERuntime.ScreenWidth: Integer;
begin
  Result := FHost.FWidth;
end;

function TJ2MERuntime.ScreenHeight: Integer;
begin
  Result := FHost.FHeight;
end;

procedure TJ2MERuntime.ResizeCanvas(Width, Height: Integer);
begin
  if (Width < 1) or (Width > 1024) or (Height < 1) or (Height > 1024) then
    raise EArgumentOutOfRangeException.Create('Java ME screen dimensions');
  if (Width = FHost.FWidth) and (Height = FHost.FHeight) then
    Exit;
  if (FHost.FScreen <> 0) and J2MEIsGameCanvas(FVM, FHost.FScreen) then
    raise ENotSupportedException.Create('GameCanvas buffer resize');
  FHost.FViewportEvidence := Default(TJ2MEViewportEvidence);
  FHost.FWidth := Width;
  FHost.FHeight := Height;
  FHost.FUI.Resize(Width, Height);
  SetLength(FHost.FPixels, Width * Height);
  SetLength(FHost.FContentPixels, Width * Height);
  for var I := 0 to Width * Height - 1 do
  begin
    FHost.FPixels[I] := $FF000000;
    FHost.FContentPixels[I] := $FF000000;
  end;
  FHost.FLayoutHeight := FHost.FUI.ContentHeight(FHost.FScreen);
  FHost.FRepaint := True;
  FHost.FHasContent := False;
  FFrameReady := True;
end;

end.

