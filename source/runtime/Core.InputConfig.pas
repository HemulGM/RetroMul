unit Core.InputConfig;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.IniFiles,
  Core.Storage, Core.Emulation.Types, System.Generics.Collections;

type
  TCoreInputPorts = record
    Devices: array[0..EmulatorMaxPlayers - 1] of string;
    Multitap: array[0..1] of Boolean;
    Expansion: string;
    FourScore, LegacyZapper, KeyboardEnabled: Boolean; // Legacy hardware ABI.
    Options: TArray<TPair<string, string>>;
    function Option(const Name, Default: string): string;
    procedure SetOption(const Name, Value: string);
    class function Defaults: TCoreInputPorts; static;
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

type
  TInputPortsReader = reference to procedure(Ini: TCustomIniFile; var Ports: TCoreInputPorts);

procedure RegisterInputPortsReader(const SystemId: string; const Reader: TInputPortsReader);

function SameInputPorts(const A, B: TCoreInputPorts): Boolean;

function ReadCoreInputPorts(Ini: TCustomIniFile; const SystemId: string = ''): TCoreInputPorts;

function LoadCoreInputPorts(const Storage: IStorage; const SystemId: string): TCoreInputPorts;

procedure UpdateMappedButtons(Code: UInt32; Pressed: Boolean; const Keys: array of UInt32; var Buttons: TEmulatorButtons);

implementation

uses
  Core.Platforms, System.Generics.Defaults;

var
  Readers: TDictionary<string, TInputPortsReader>;

procedure RegisterInputPortsReader(const SystemId: string; const Reader: TInputPortsReader);
begin
  if (SystemId.Trim = '') or not Assigned(Reader) then
    raise EArgumentException.Create('Invalid input ports reader');
  Readers.Add(SystemId.Trim, Reader);
end;

function TCoreInputPorts.Option(const Name, Default: string): string;
begin
  Result := Default;
  for var Item in Options do
    if SameText(Item.Key, Name) then
      Exit(Item.Value);
end;

procedure TCoreInputPorts.SetOption(const Name, Value: string);
begin
  Options := Copy(Options);
  for var I := 0 to High(Options) do
    if SameText(Options[I].Key, Name) then
    begin
      Options[I].Value := Value;
      Exit;
    end;
  Options := Options + [TPair<string, string>.Create(Name, Value)];
end;

class function TCoreInputPorts.Defaults: TCoreInputPorts;
begin
  Result := Default(TCoreInputPorts);
  for var I := 0 to High(Result.Devices) do
    Result.Devices[I] := 'auto';
  Result.Expansion := 'auto';
  Result.KeyboardEnabled := True;
end;

procedure UpdateMappedButtons(Code: UInt32; Pressed: Boolean; const Keys: array of UInt32; var Buttons: TEmulatorButtons);
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

  if Length(A.Options) <> Length(B.Options) then
    Exit;
  for var Item in A.Options do
    if B.Option(Item.Key, #0) <> Item.Value then
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

function ReadCoreInputPorts(Ini: TCustomIniFile; const SystemId: string): TCoreInputPorts;
begin
  Result := TCoreInputPorts.Defaults;
  for var i := 0 to High(Result.Devices) do
    Result.Devices[i] := Ini.ReadString('Ports', 'Port' + IntToStr(i + 1), Result.Devices[i]).ToLower;
  for var i := 0 to 1 do
    Result.Multitap[i] := Ini.ReadBool('Input', 'Multitap' + IntToStr(i + 1), Result.Multitap[i]);
  Result.Expansion := Ini.ReadString('Ports', 'Expansion', Result.Expansion).ToLower;

  Result.KeyboardEnabled := Ini.ReadBool('Ports', 'KeyboardEnabled', Result.KeyboardEnabled);
  var Id := SystemId;
  if Id = '' then
    Id := ChangeFileExt(ExtractFileName(Ini.FileName), '');
  var Reader: TInputPortsReader;
  if Readers.TryGetValue(TPlatformRegistry.CanonicalId(Id), Reader) then
    Reader(Ini, Result);
end;

function LoadCoreInputPorts(const Storage: IStorage; const SystemId: string): TCoreInputPorts;
begin
  var Ini := Storage.ReadConfig(Storage.ConfigFile(SystemId));
  try
    Result := ReadCoreInputPorts(Ini, SystemId);
  finally
    Ini.Free;
  end;
end;

initialization
  Readers := TDictionary<string, TInputPortsReader>.Create(TIStringComparer.Ordinal);

finalization
  Readers.Free;

end.

