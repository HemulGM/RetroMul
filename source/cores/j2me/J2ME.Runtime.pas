unit J2ME.Runtime;

interface

uses
  System.Math, System.SysUtils, System.Generics.Collections, JVM.Types,
  JVM.ClassFile, JVM.Runtime, Java.Bootstrap, J2ME.Suite, J2ME.Media, J2ME.RMS,
  J2ME.LCDUI, J2ME.Network, Core.Bluetooth.Types, Core.Messaging.Types,
  J2ME.Messaging, J2ME.Bluetooth, J2ME.Nokia.UI, J2ME.Nokia.Sound, J2ME.Effects,
  J2ME.Siemens.Game;

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

  TJ2MEHost = class(TJavaHost)
  private
    FSuite: TJ2MESuite;
    FVM: TJVM;
    FDisplay, FScreen: Integer;
    FWidth, FHeight: Integer;
    FPixels, FContentPixels: TArray<UInt32>;
    FRepaint, FNotifyDestroyed, FNotifyPaused, FHasContent: Boolean;
    FRootMIDlet: Integer;
    FMIDletStarted, FGuestPaused, FResumeRequested: Boolean;
    FLifecycleError: string;
    FPhysicalKeys: TDictionary<Integer, Boolean>;
    FDisplayChanges: TQueue<TJ2MEDisplayChange>;
    FFlushCount: UInt64;
    FMedia: TJ2MEMedia;
    FRMS: TJ2MERMS;
    FNetwork: TJ2MENetwork;
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
    function DisplayGraphics(Screen: Integer): Integer;
    procedure QueueUI(const ClassName, Name, Descriptor: string; const Args: array of TJVMValue);
    procedure QueuePaint;
    procedure ChangeScreen(Screen: Integer);
    procedure PostAlertTimeout(Screen, Generation: Integer);
  public
    constructor Create(Suite: TJ2MESuite; Width, Height: Integer; const Bluetooth: IBluetoothProvider; const Messaging: IMessagingProvider);
    destructor Destroy; override;
    procedure Install(VM: TJVM);
    function LoadClass(const Name: string): TBytes; override;
    function LoadResource(const Name: string; out Data: TBytes): Boolean; override;
    function LoadClassResource(const ClassName, Name: string; out Data: TBytes): Boolean; override;
    function GetProperty(const Name: string; out Value: string): Boolean; override;
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
    FHostPaused, FStopPending: Boolean;
    FMediaContext: Integer;
    FMediaCallRunning: Boolean;
    FMediaError, FRMSError: string;
    FRMSContext: Integer;
    FRMSCallRunning: Boolean;
    FBluetoothContext: Integer;
    FBluetoothCallRunning: Boolean;
    FBluetoothError: string;
    FMessagingContext: Integer;
    FMessagingCallRunning: Boolean;
    FMessagingError: string;
    procedure Enqueue(const ClassName, Name, Descriptor: string; const Args: array of TJVMValue);
    procedure ClearQueue;
    function GetBluetoothProvider: IBluetoothProvider;
    function GetMessagingProvider: IMessagingProvider;
  public
    constructor Create(Suite: TJ2MESuite; Width: Integer = 240; Height: Integer = 320; const Bluetooth: IBluetoothProvider = nil; const Messaging: IMessagingProvider = nil);
    destructor Destroy; override;
    procedure Start(MIDletIndex: Integer = 0);
    procedure Tick(InstructionBudget: Integer);
    function NeedsExecution: Boolean;
    procedure Pause;
    procedure Resume;
    procedure DestroyApp;
    procedure KeyEvent(KeyCode: Integer; Pressed: Boolean);
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
    property VM: TJVM read FVM;
    property BluetoothProvider: IBluetoothProvider read GetBluetoothProvider;
    property MessagingProvider: IMessagingProvider read GetMessagingProvider;
  end;

implementation

uses
  System.DateUtils, System.Diagnostics, Java.Classes, J2ME.Graphics, J2ME.Image,
  J2ME.Font, J2ME.GameCanvas, J2ME.Game.Layers, Core.Bluetooth, Core.Messaging,
  J2ME.Bluetooth.Data, J2ME.Siemens.Graphics, J2ME.Resources;

constructor TJ2MEHost.Create(Suite: TJ2MESuite; Width, Height: Integer; const Bluetooth: IBluetoothProvider; const Messaging: IMessagingProvider);
begin
  inherited Create;
  if Suite = nil then
    raise EArgumentNilException.Create('Suite');
  if (Width < 1) or (Width > 1024) or (Height < 1) or (Height > 1024) then
    raise EArgumentOutOfRangeException.Create('Java ME screen dimensions');
  FSuite := Suite;
  FWidth := Width;
  FHeight := Height;
  FBluetooth := Bluetooth;
  if FBluetooth = nil then
    FBluetooth := CreateUnavailableBluetoothProvider;
  FMessagingProvider := Messaging;
  if FMessagingProvider = nil then
    FMessagingProvider := CreateUnavailableMessagingProvider;
  FPhysicalKeys := TDictionary<Integer, Boolean>.Create;
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
  FUIJobs.Free;
  FUI.Free;
  FRMS.Free;
  FMedia.Free;
  FDisplayChanges.Free;
  FPhysicalKeys.Free;
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
  FEffects := TJ2MEDeviceEffects.Create(MonotonicMillis);
  InstallJavaBootstrap(VM);
  FMedia := TJ2MEMedia.Create(VM);
  FMedia.Install;
  FNetwork := TJ2MENetwork.Create(VM);
  FNetwork.Install;
  InstallJ2MEResources(VM);
  FMessaging := TJ2MEMessaging.Create(VM, FMessagingProvider);
  FMessaging.Install;
  FNetwork.ProtocolOpen :=
    function(URL: string; Mode: Integer; Timeouts: Boolean): Integer
    begin
      Result := -1;
      var P := Pos(':', URL);
      var Scheme := Copy(URL, 1, P - 1);
      if SameText(Scheme, 'resource') then
        Result := OpenJ2MEResource(VM, URL, Mode);
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
  FUI.Install;
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
    B.Finish('$deliverPaint', '(Ljavax/microedition/lcdui/Graphics;)V', JVM_ACC_PRIVATE, 2, 2);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  C := AddClass('javax/microedition/lcdui/Display', 'java/lang/Object');
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
  C.AddNative('vibrate', '(I)Z');
  C.AddNative('flashBacklight', '(I)Z');
  InstallJ2MEGraphics(VM);
  InstallJ2MEImage(VM);
  InstallJ2MEFont(VM);
  InstallJ2MEGameCanvas(VM);
  InstallJ2MEGameLayers(VM);
  InstallJ2MEGameCanvas(VM, True);
  InstallJ2MEGameLayers(VM, True);
  FNokiaUI := TJ2MENokiaUI.Create(VM, FEffects);
  FNokiaUI.Install;
  FNokiaSound := TJ2MENokiaSound.Create(VM);
  FNokiaSound.Install;
  FSiemens := TJ2MESiemensGame.Create(VM, FEffects);
  FSiemens.Install;
  InstallJ2MESiemensGraphics(VM);
  FDisplay := VM.NewObject('javax/microedition/lcdui/Display');
  VM.AddRoot(FDisplay);
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
  if not J2MECanonicalResourceName(Name, Key) then
    Exit;
  // MIDP resources cannot expose classfiles. Class loading uses LoadClass instead.
  if Key.EndsWith('.class') then
    Exit;
  Result := FSuite.HasResource(Key);
  if Result then
    Data := FSuite.ReadResource(Key);
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
  Current := Now;
  Result := DateTimeToUnix(TTimeZone.local.ToUniversalTime(Current), True) * 1000 + MilliSecondOf(Current);
end;

function TJ2MEHost.GetProperty(const Name: string; out Value: string): Boolean;
begin
  Result := True;
  if (FMessaging <> nil) and FMessaging.GetProperty(Name, Value) then
    Exit(True);
  if Name = 'microedition.platform' then
    Value := 'RetroMul'
  else if Name = 'microedition.configuration' then
    Value := 'CLDC-1.1'
  else if Name = 'microedition.profiles' then
    Value := 'MIDP-2.0'
  else if Name = 'microedition.encoding' then
    Value := DefaultEncoding
  else if Name = 'microedition.locale' then
    Value := 'en-US'
  else
    Result := inherited GetProperty(Name, Value);
end;

function TJ2MEHost.MonotonicMillis: Int64;
var
  Stamp, Frequency: Int64;
begin
  Stamp := TStopwatch.GetTimeStamp;
  Frequency := TStopwatch.Frequency;
  Result := (Stamp div Frequency) * 1000 + ((Stamp mod Frequency) * 1000) div Frequency;
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
  if FNokiaSound.Handles(C) then
    Exit(FNokiaSound.Invoke(Method, Arguments));
  if FNokiaUI.Handles(C) then
    Exit(FNokiaUI.Invoke(Method, Arguments));
  if FMessaging.Handles(Method.Owner.Name) then
    Exit(FMessaging.Invoke(Method, Arguments));
  if HandlesJ2MEResources(C) then
    Exit(InvokeJ2MEResources(VM, Method, Arguments));
  if FNetwork.Handles(Method) then
    Exit(FNetwork.Invoke(Method, Arguments));
  if HandlesJ2MEBluetoothData(C) then
    Exit(InvokeJ2MEBluetoothData(VM, Method, Arguments));
  if FBluetoothAPI.Handles(C) then
    Exit(FBluetoothAPI.Invoke(Method, Arguments));
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
    Result := InvokeJ2MEGameCanvas(VM, Method, Arguments, FUI.IsShown(Arg(0).AsRef), FContentPixels, FWidth, I, Flushed);
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
      Exit(TJVMValue.Int(Ord(S = 'javax.microedition.io.Connector.http')));
    end;
    if N = 'getAppProperty' then
    begin
      S := VM.GetObject(Arg(1).AsRef).Text;
      if not FSuite.HasProperty(S) then
        Exit(TJVMValue.Ref(0));
      Exit(TJVMValue.Ref(VM.NewString(FSuite.GetProperty(S))));
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
      VM.GetObject(Arg(1).AsRef);
      if FRepaint then
        QueuePaint;
      QueueUI(VM.GetObject(Arg(1).AsRef).ClassName, 'run', '()V', [Arg(1)]);
      Exit;
    end;
    if (N = 'vibrate') or (N = 'flashBacklight') then
    begin
      if Arg(1).AsInt < 0 then
        VM.RaiseJava('java/lang/IllegalArgumentException');
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
    if N = 'isShown' then
      Exit(TJVMValue.Int(Ord(Arg(0).AsRef = FScreen)));
    if N = 'repaint' then
    begin
      if Arg(0).AsRef <> FScreen then
        Exit;
      if (Length(Arguments) = 5) and ((Arg(3).AsInt <= 0) or (Arg(4).AsInt <= 0) or
        (Arg(1).AsInt >= FWidth) or (Arg(2).AsInt >= FHeight) or
        (Int64(Arg(1).AsInt) + Arg(3).AsInt <= 0) or (Int64(Arg(2).AsInt) + Arg(4).AsInt <= 0)) then
        Exit;
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
    if N = '$visibility' then
    begin
      var O := VM.GetObject(Arg(0).AsRef);
      Shown := Arg(1).AsInt <> 0;
      if Shown <> FUI.IsShown(Arg(0).AsRef) then
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
      if not FUI.IsShown(Arg(0).AsRef) or not FRepaint then
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
      FRepaint := False;
      Exit(TJVMValue.Int(1));
    end;
    if N = '$painted' then
    begin
      if Arg(0).AsRef = FScreen then
      begin
        FHasContent := True;
        FUI.Render(FPixels, FContentPixels, MonotonicMillis);
        Inc(FFlushCount);
      end;
      Exit;
    end;
    if N = 'serviceRepaints' then
    begin
      if (Arg(0).AsRef = FScreen) and FRepaint then
        VM.InvokeGuest(VM.LoadClass('javax/microedition/lcdui/Canvas').FindMethod('$deliverPaint', '(Ljavax/microedition/lcdui/Graphics;)V'),
          [Arg(0), TJVMValue.Ref(DisplayGraphics(FScreen))]);
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
    if (N = 'hasPointerEvents') or (N = 'hasPointerMotionEvents') or (N = 'hasRepeatEvents') then
      Exit(TJVMValue.Int(0));
    if N = 'getKeyName' then
    begin
      I := Arg(1).AsInt;
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
      I := J2MEGameAction(Arg(1).AsInt);
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
      Exit(TJVMValue.Int(I));
    end;
  end;
  if C = 'com/nokia/mid/ui/DirectUtils' then
    Exit(InvokeJ2MEDirectUtils(VM, Method, Arguments));
  if C = 'javax/microedition/lcdui/Graphics' then
    Exit(InvokeJ2MEGraphics(VM, Method, Arguments, FContentPixels, FWidth, FUI.ContentHeight(FScreen)));
  Result := inherited;
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
  FUI.Current(Screen);
  FVM.RemoveRoot(FScreen);
  FScreen := Screen;
  FHasContent := False;
  FLayoutHeight := FUI.ContentHeight(Screen);
  FRepaint := Screen <> 0;
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

procedure TJ2MEHost.QueuePaint;
begin
  if (FScreen <> 0) and FUI.IsCanvas(FScreen) then
    QueueUI('javax/microedition/lcdui/Canvas', '$deliverPaint', '(Ljavax/microedition/lcdui/Graphics;)V',
      [TJVMValue.Ref(FScreen), TJVMValue.Ref(DisplayGraphics(FScreen))]);
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

function TJ2MERuntime.NeedsExecution: Boolean;
begin
  Result := False;
  if FState in [TJ2MEState.Destroyed, TJ2MEState.Faulted] then
    Exit;
  if FStopPending then
    Exit(True);
  if FSuspendedStartup or (FState in [TJ2MEState.Created, TJ2MEState.Destroyed, TJ2MEState.Faulted]) then
    Exit;
  if FHostPaused and (FState = TJ2MEState.Paused) and (FPendingLifecycle = '') then
    Exit;
  Result := FVM.HasRunnableWork or (FQueue.Count <> 0) or (FHost.FResumeRequested and not FHostPaused);
  if FState <> TJ2MEState.Paused then
    Result := Result or (FEventQueue.Count <> 0) or (FHost.FUIJobs.Count <> 0) or
      (FHost.FDisplayChanges.Count <> 0) or FHost.FNokiaSound.HasEvents;
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
    else if not FHostPaused or (FState <> TJ2MEState.Paused) or (FPendingLifecycle <> '') then
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
        FState := TJ2MEState.Active;
        if (FVM.ReturnValue.AsInt = 1) or FHost.FGuestPaused then
        begin
          FState := TJ2MEState.Paused;
          FHost.FGuestPaused := True;
        end;
        if FVM.ReturnValue.AsInt = 2 then
        begin
          FState := TJ2MEState.Destroyed;
          FError := FHost.FLifecycleError;
        end;
        FPendingLifecycle := '';
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
    if FHost.FResumeRequested and not FHostPaused and (FState = TJ2MEState.Paused) and (FPendingLifecycle = '') and (FCurrentCall.Name = '') then
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
    if not FHostPaused and not FMessagingCallRunning and FHost.FMessaging.TakeEvent(MessageEvent) then
    begin
      try
        if FMessagingContext = 0 then
          FMessagingContext := FVM.CreateExecutionContext;
        FVM.BeginContextCall(FMessagingContext, 'javax/wireless/messaging/MessageConnection$Dispatcher', '$deliver',
          '(Ljavax/wireless/messaging/MessageConnection;I)V', [TJVMValue.Ref(MessageEvent.Connection), TJVMValue.Int(MessageEvent.Generation)]);
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
          '(Ljavax/microedition/media/Player;Ljava/lang/String;Ljava/lang/Object;)V',
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
        if FHost.FUI.IsCanvas(Change.Previous) then
          Enqueue('javax/microedition/lcdui/Canvas', '$visibility', '(Z)V', [TJVMValue.Ref(Change.Previous), TJVMValue.Int(0)]);
        if Change.Current <> 0 then
        begin
          if FHost.FUI.IsCanvas(Change.Current) then
          begin
            Enqueue('javax/microedition/lcdui/Canvas', '$size', '()V', [TJVMValue.Ref(Change.Current)]);
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
    if (FHost.FScreen <> 0) and (FHost.FHasContent or not FHost.FUI.IsCanvas(FHost.FScreen)) and FHost.FUI.NeedsRender(FHost.MonotonicMillis) then
    begin
      FHost.FUI.Render(FHost.FPixels, FHost.FContentPixels, FHost.MonotonicMillis);
      Inc(FFrameNumber);
      FFrameReady := True;
    end;
    if FState in [TJ2MEState.Starting, TJ2MEState.Active] then
      FHost.FUI.PollAlert(FHost.MonotonicMillis);
    if (FEventQueue.Count = 0) and (FVM.ExecutionContextState(FEventContext) <> TJVMState.Running) and
      (FState in [TJ2MEState.Starting, TJ2MEState.Active]) and FHost.FRepaint and FHost.FUI.IsShown(FHost.FScreen) and FHost.FUI.IsCanvas(FHost.FScreen) then
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
    if (FState <> TJ2MEState.Paused) and (FVM.ExecutionContextState(FEventContext) <> TJVMState.Running) and (FEventQueue.Count > 0) then
    begin
      Job := FEventQueue.Dequeue;
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

procedure TJ2MERuntime.Pause;
begin
  FHostPaused := True;
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
  FHostPaused := False;
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
  FSuspendedStartup := False;
  ClearQueue;
  FPendingLifecycle := 'destroyApp';
  Enqueue(FClassName, 'destroyApp', '(Z)V', [TJVMValue.Ref(FMIDlet), TJVMValue.Int(1)]);
end;

procedure TJ2MERuntime.KeyEvent(KeyCode: Integer; Pressed: Boolean);
var
  FreshPress: Boolean;
begin
  if not (FState in [TJ2MEState.Active, TJ2MEState.Starting]) or (FHost.FScreen = 0) then
    Exit;
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
  if FEventQueue.Count >= 256 then
    raise EJVMError.Create('MIDlet input queue overflow');
  if Pressed and not FreshPress then
    Exit;
  Enqueue('javax/microedition/lcdui/Displayable', '$key', '(IZ)V',
    [TJVMValue.Ref(FHost.FScreen), TJVMValue.Int(KeyCode), TJVMValue.Int(Ord(Pressed))]);
end;

procedure TJ2MERuntime.TextInput(const Text: string);
begin
  if not (FState in [TJ2MEState.Active, TJ2MEState.Starting]) or (FHost.FScreen = 0) or (Text = '') then
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
  if FHostPaused or (FState in [TJ2MEState.Paused, TJ2MEState.Destroyed, TJ2MEState.Faulted]) then
  begin
    CancelVibration;
    Exit(Default(TJ2MEVibrationSample));
  end;
  Result := FHost.FEffects.TakeVibration(FHost.MonotonicMillis);
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
  Pixels := Copy(FHost.FPixels);
  FHost.FNokiaUI.ApplyBacklight(Pixels);
  Number := FFrameNumber;
  FFrameReady := False;
end;

function TJ2MERuntime.RenderAudio(Frames: Integer): TArray<SmallInt>;
begin
  if (Frames < 0) or (Frames > 8192) then
    raise EArgumentOutOfRangeException.Create('Media render block');
  if FState in [TJ2MEState.Created, TJ2MEState.Paused, TJ2MEState.Destroyed, TJ2MEState.Faulted] then
  begin
    Result := nil;
    SetLength(Result, Frames * 2);
    Exit;
  end;
  var Mix := FHost.FMedia.RenderMix(Frames);
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

end.

