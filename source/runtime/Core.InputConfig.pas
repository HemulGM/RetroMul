unit Core.InputConfig;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.IniFiles,
  Core.Storage, Core.Emulation.Types;

type
  TCoreInputPorts = record
    Devices: array[0..11] of string;
    Multitap: array[0..1] of Boolean;
    Expansion: string;
    FourScore, LegacyZapper, KeyboardEnabled: Boolean;
  end;

  IEmulationInputPorts = interface
    ['{4B99FEF5-1269-466C-BD25-E5819B4D0152}']
    // Frontend thread, active core. Does not restart, reset or resume the game.
    procedure ApplyInputPorts(const Ports: TCoreInputPorts);
  end;

  TInputPortsAction = reference to procedure(const Ports: TCoreInputPorts);

  // Connection changes execute between frames, including while paused.
  // The caller waits for completion before updating its peripheral controls.
  TInputPortsCommand = class
  private
    FLock, FCommandLock: TCriticalSection;
    FDone: TEvent;
    FCurrent, FRequested: TCoreInputPorts;
    FPending, FInitialized: Boolean;
    FError: string;
  public
    constructor Create;
    destructor Destroy; override;
    function GetPorts: TCoreInputPorts;
    procedure Apply(Worker: TThread; const Ports: TCoreInputPorts; Wake: TEvent = nil);
    procedure Process(const Action: TInputPortsAction);
  end;

function SameInputPorts(const A, B: TCoreInputPorts): Boolean;

function ReadCoreInputPorts(Ini: TCustomIniFile): TCoreInputPorts;

function LoadCoreInputPorts(const Storage: IStorage; const SystemId: string): TCoreInputPorts;

procedure UpdateMappedButtons(Code: UInt32; Pressed: Boolean;
  const Keys: array of UInt32; var Buttons: TEmulatorButtons);

implementation

procedure UpdateMappedButtons(Code: UInt32; Pressed: Boolean;
  const Keys: array of UInt32; var Buttons: TEmulatorButtons);
begin
  if Code = 0 then
    Exit;
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    if (Ord(Button) < Length(Keys)) and (Code = Keys[Ord(Button)]) then
      if Pressed then
        Include(Buttons, Button)
      else
        Exclude(Buttons, Button);
end;

function SameInputPorts(const A, B: TCoreInputPorts): Boolean;
begin
  Result := False;
  for var i := 0 to High(A.Devices) do
    if A.Devices[i] <> B.Devices[i] then
      Exit;

  for var i := 0 to High(A.Multitap) do
    if A.Multitap[i] <> B.Multitap[i] then
      Exit;

  Result := (A.Expansion = B.Expansion) and (A.FourScore = B.FourScore) and
    (A.LegacyZapper = B.LegacyZapper) and (A.KeyboardEnabled = B.KeyboardEnabled);
end;

constructor TInputPortsCommand.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FCommandLock := TCriticalSection.Create;
  FDone := TEvent.Create(nil, True, False, '');
end;

destructor TInputPortsCommand.Destroy;
begin
  FDone.Free;
  FCommandLock.Free;
  FLock.Free;
  inherited;
end;

function TInputPortsCommand.GetPorts: TCoreInputPorts;
begin
  FLock.Enter;
  try
    Result := FCurrent;
  finally
    FLock.Leave;
  end;
end;

procedure TInputPortsCommand.Apply(Worker: TThread; const Ports: TCoreInputPorts; Wake: TEvent);
begin
  FCommandLock.Enter;
  try
    FLock.Enter;
    try
      if FInitialized and SameInputPorts(FCurrent, Ports) then
        Exit;

      if (Worker = nil) or Worker.Suspended then
      begin
        FCurrent := Ports;
        FInitialized := True;
        Exit;
      end;

      if Worker.Finished then
        raise EInvalidOpException.Create('Emulation worker is not running');

      FRequested := Ports;
      FError := '';
      FDone.ResetEvent;
      FPending := True;
    finally
      FLock.Leave;
    end;
    if Wake <> nil then
      Wake.SetEvent;
    while FDone.WaitFor(50) <> wrSignaled do
      if Worker.Finished then
        raise EInvalidOpException.Create('Emulation stopped before connecting input devices');

    FLock.Enter;
    try
      if FError <> '' then
        raise EInvalidOpException.Create(FError);
    finally
      FLock.Leave;
    end;
  finally
    FCommandLock.Leave;
  end;
end;

procedure TInputPortsCommand.Process(const Action: TInputPortsAction);
begin
  var Ports: TCoreInputPorts;
  FLock.Enter;
  try
    if not FPending then
      Exit;

    Ports := FRequested;
  finally
    FLock.Leave;
  end;
  var ErrorText := '';
  try
    if Assigned(Action) then
      Action(Ports);
  except
    on E: Exception do
      ErrorText := E.Message;
  end;
  FLock.Enter;
  try
    FError := ErrorText;
    if ErrorText = '' then
    begin
      FCurrent := Ports;
      FInitialized := True;
    end;
    FPending := False;
    FDone.SetEvent;
  finally
    FLock.Leave;
  end;
end;

function ReadCoreInputPorts(Ini: TCustomIniFile): TCoreInputPorts;
begin
  for var i := 0 to High(Result.Devices) do
    Result.Devices[i] := Ini.ReadString('Ports', 'Port' + IntToStr(i + 1), 'auto').ToLower;
  for var i := 0 to 1 do
    Result.Multitap[i] := Ini.ReadBool('Input', 'Multitap' + IntToStr(i + 1), False);
  Result.Expansion := Ini.ReadString('Ports', 'Expansion', 'auto').ToLower;
  Result.FourScore := Ini.ReadBool('Input', 'FourScore', False);
  Result.LegacyZapper := Ini.ReadBool('Input', 'Zapper', False);
  Result.KeyboardEnabled := Ini.ReadBool('Ports', 'KeyboardEnabled', True);
end;

function LoadCoreInputPorts(const Storage: IStorage; const SystemId: string): TCoreInputPorts;
begin
  var Ini := Storage.ReadConfig(Storage.ConfigFile(SystemId));
  try
    Result := ReadCoreInputPorts(Ini);
  finally
    Ini.Free;
  end;
end;

end.

