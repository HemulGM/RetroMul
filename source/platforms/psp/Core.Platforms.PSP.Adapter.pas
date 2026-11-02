unit Core.Platforms.PSP.Adapter;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, System.SyncObjs,
  Core.Storage, Core.Emulation, PSP.Types, PSP.Media, PSP.Console,
  RM.Vulkan.TexScale, Core.Platforms.PSP.Playback, Core.Platforms.PSP.Renderer;

type
  TPSPKeyMap = array[TEmulatorButton] of UInt32;

  TPSPConfig = class(TEmulatorConfigBase)
  private
    FKeys: TPSPKeyMap;
    FRecompiler: Boolean;
    FRenderer: TPSPRenderer;
    FResolution: Integer;
    FTextureScale: Integer;
    FTextureFilter: TTexScaleFilter;
    FLanguage, FButtonSwap: Integer;
    FNickname: string;
    FFontDirectory: string;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage);
    property Keys: TPSPKeyMap read FKeys;
    // The CPU through its recompiler (Emulation/Execution jit), else interpreted.
    property Recompiler: Boolean read FRecompiler write FRecompiler;
    // Applied by Start, not by live Configure or a guest Reset/LoadExec.
    property Renderer: TPSPRenderer read FRenderer write FRenderer;
    // The Vulkan HLE renderer's internal resolution, 1 to 8 times the PSP's.
    // Applied by Start, as the renderer.
    property Resolution: Integer read FResolution write FResolution;
    // The Vulkan HLE renderer's texture scaling above 1x: 0 none, else 2 to 6
    // (Video/TextureScale), with the filter (Video/TextureFilter). Applied by
    // Start, as the renderer.
    property TextureScale: Integer read FTextureScale write FTextureScale;
    property TextureFilter: TTexScaleFilter read FTextureFilter write FTextureFilter;
    property Language: Integer read FLanguage;
    property ButtonSwap: Integer read FButtonSwap;
    property Nickname: string read FNickname;
    property FontDirectory: string read FFontDirectory write FFontDirectory;
  end;

  TPSPWorker = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FConsole: TPSPConsole;
    FStorage: IStorage;
    FAudio: TPSPAudioPlayback;
    FAudioEnabled: Boolean;
    FVolume: Single;
    FInput: TEmulatorInput;
    FPaused, FReset, FAvailable: Boolean;
    FRecompiler: Boolean;
    FFrame: TEmulatorFrame;
    FError: string;
    FRenderer: TPSPRenderer;
    FResolution: Integer;
    FTextureScale: Integer;
    FTextureFilter: TTexScaleFilter;
    FRendererStatus: string;
    FRate: TEmulationFrameRate;
    FSnapshotDone: TEvent;
    FSnapshotPending, FSnapshotBusy, FSnapshotLoading, FSnapshotCancel: Boolean;
    FSnapshotName, FSnapshotError, FSnapshotDirectory: string;
    FSnapshotProgress, FSnapshotTotal: UInt64;
    function ProcessSnapshot(var Renderer: TPSPRendererSession): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const ProgramData: TPSPProgram; const Storage: IStorage; Renderer: TPSPRenderer = prCPU;
      const FontDirectory: string = ''; const SnapshotDirectory: string = ''; Resolution: Integer = 1;
      TextureScale: Integer = 0; TextureFilter: TTexScaleFilter = tfXBRZ);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; Paused: Boolean; AudioEnabled: Boolean = True; Volume: Single = 1;
      Recompiler: Boolean = True);
    procedure RequestReset;
    procedure Join;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function RendererStatus: string;
    procedure BeginSnapshot(const Name: string; Loading: Boolean);
    procedure Snapshot(const Name: string; Loading: Boolean);
    function SnapshotStatus(out Done, Total: UInt64; out Error: string): Boolean;
    procedure CancelSnapshot;
  end;

  TPSPCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationSnapshotLocation, IEmulationSnapshotOperation)
  private
    FProgram: TPSPProgram;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TPSPConfig;
    FWorker: TPSPWorker;
    FKeyboard, FGamepad: TEmulatorInput;
    FPaused: Boolean;
    FError: string;
    FRendererStatus: string;
    FSnapshotDirectory: string;
    procedure Configure;
  public
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string; const ImageName: string = '');
    destructor Destroy; override;
    function GetName: string;
    function GetSystemId: string;
    function GetSupportsSnapshots: Boolean;
    function GetHasCoinAcceptor: Boolean;
    procedure InsertCoin1;
    procedure InsertCoin2;
    procedure Start;
    procedure Stop;
    procedure Pause;
    procedure Resume;
    procedure Reset;
    procedure ClearInput;
    procedure SetKeyState(Code: UInt32; Pressed: Boolean);
    procedure SetGamepadInput(const Input: TEmulatorInput);
    function GetInputState: TEmulatorInput;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function GetSnapshotDirectory: string;
    procedure BeginSnapshot(const Name: string; Loading: Boolean);
    function SnapshotStatus(out Done, Total: UInt64; out Error: string): Boolean;
    procedure CancelSnapshot;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
    function RendererStatus: string;
  end;

implementation

uses
{$IFDEF MSWINDOWS}
  Winapi.MMSystem,
{$ENDIF}
    Core.MediaArchive, System.UITypes, System.Diagnostics, System.Math, Core.Platforms, Core.Platforms.PSP.Archive,
    PSP.Settings, Core.Snapshots, Core.SavePaths;

const
  KeyNames: array[TEmulatorButton] of string =
    ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');

constructor TPSPConfig.Create(const FileName: string; const Storage: IStorage);
const
  DefaultKeys: TPSPKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkShift, vkReturn, vkQ, vkA, vkS, vkW, 0);
begin
  inherited Create(FileName, Storage);
  FKeys := DefaultKeys;
  FRecompiler := True;
  FRenderer := prCPU;
  FResolution := 1;
  FLanguage := 1;
  FButtonSwap := 1;
  FNickname := 'RetroMul';
end;

procedure TPSPConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
  FRecompiler := not SameText(Ini.ReadString('Emulation', 'Execution', 'jit'), 'interpreter');
  FRenderer := PSPRendererFromName(Ini.ReadString('Video', 'Renderer', 'cpu'));
  FResolution := EnsureRange(Ini.ReadInteger('Video', 'Resolution', FResolution), 1, 8);
  FTextureScale := EnsureRange(Ini.ReadInteger('Video', 'TextureScale', FTextureScale), 0, TexScaleMax);
  if FTextureScale = 1 then
    FTextureScale := 0;
  FTextureFilter := TexScaleFilterFromName(Ini.ReadString('Video', 'TextureFilter',
    TexScaleFilterName(FTextureFilter)));
  FLanguage := EnsureRange(Ini.ReadInteger('System', 'Language', FLanguage), 0, 11);
  FButtonSwap := EnsureRange(Ini.ReadInteger('System', 'ButtonSwap', FButtonSwap), 0, 1);
  FNickname := Ini.ReadString('System', 'Nickname', FNickname);
  FFontDirectory := Ini.ReadString('System', 'FontDirectory', '');
end;

procedure TPSPConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
  if FRecompiler then
    Ini.WriteString('Emulation', 'Execution', 'jit')
  else
    Ini.WriteString('Emulation', 'Execution', 'interpreter');
  Ini.WriteString('Video', 'Renderer', PSPRendererName(FRenderer));
  Ini.WriteInteger('Video', 'Resolution', FResolution);
  Ini.WriteInteger('Video', 'TextureScale', FTextureScale);
  Ini.WriteString('Video', 'TextureFilter', TexScaleFilterName(FTextureFilter));
  Ini.WriteInteger('System', 'Language', FLanguage);
  Ini.WriteInteger('System', 'ButtonSwap', FButtonSwap);
  Ini.WriteString('System', 'Nickname', FNickname);
  Ini.WriteString('System', 'FontDirectory', FFontDirectory);
end;

constructor TPSPWorker.Create(const ProgramData: TPSPProgram; const Storage: IStorage; Renderer: TPSPRenderer;
  const FontDirectory, SnapshotDirectory: string; Resolution, TextureScale: Integer; TextureFilter: TTexScaleFilter);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRenderer := Renderer;
  FResolution := Resolution;
  FTextureScale := TextureScale;
  FTextureFilter := TextureFilter;
  FStorage := Storage;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshotDone := TEvent.Create(nil, True, False, '');
  FSnapshotDirectory := SnapshotDirectory;
  FConsole := TPSPConsole.Create(ProgramData, Storage, '', '', FontDirectory, True);
end;

destructor TPSPWorker.Destroy;
begin
  Join;
  inherited;
  FConsole.Free;
  FAudio.Free;
  FWake.Free;
  FSnapshotDone.Free;
  FLock.Free;
end;

procedure TPSPWorker.BeginSnapshot(const Name: string; Loading: Boolean);
begin
  ValidateSnapshotName(Name);
  FLock.Acquire;
  try
    if Suspended or Finished or Terminated then
      raise EInvalidOpException.Create('PSP worker is not running');
    if FSnapshotBusy then
      raise EInvalidOpException.Create('A PSP snapshot operation is already running');
    FSnapshotDone.ResetEvent;
    FSnapshotName := Name;
    FSnapshotLoading := Loading;
    FSnapshotCancel := False;
    FSnapshotProgress := 0;
    FSnapshotTotal := 0;
    FSnapshotError := '';
    FSnapshotBusy := True;
    FSnapshotPending := True;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TPSPWorker.Snapshot(const Name: string; Loading: Boolean);
begin
  BeginSnapshot(Name, Loading);
  while FSnapshotDone.WaitFor(50) <> wrSignaled do
    if Finished then
      raise EInvalidOpException.Create('PSP worker stopped during the snapshot');
  var Done, Total: UInt64;
  var Error: string;
  SnapshotStatus(Done, Total, Error);
  if Error <> '' then
    raise EReadError.Create(Error);
end;

function TPSPWorker.SnapshotStatus(out Done, Total: UInt64; out Error: string): Boolean;
begin
  FLock.Acquire;
  try
    Result := FSnapshotBusy;
    Done := FSnapshotProgress;
    Total := FSnapshotTotal;
    Error := FSnapshotError;
  finally
    FLock.Release;
  end;
end;

procedure TPSPWorker.CancelSnapshot;
begin
  FLock.Acquire;
  try
    FSnapshotCancel := True;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

function TPSPWorker.ProcessSnapshot(var Renderer: TPSPRendererSession): Boolean;
begin
  FLock.Acquire;
  var Name: string;
  var Loading: Boolean;
  try
    Result := FSnapshotPending;
    if not Result then
      Exit;
    Name := FSnapshotName;
    Loading := FSnapshotLoading;
    FSnapshotPending := False;
  finally
    FLock.Release;
  end;
  var Error := '';
  try
    var Path := ResolveSnapshotPath(FSnapshotDirectory, Name);
    if Loading then
    begin
      var Candidate := FConsole.RestoreSnapshot(Path,
          function(Done, Total: UInt64): Boolean
          begin
            FLock.Acquire;
            try
              FSnapshotProgress := Done;
              FSnapshotTotal := Total;
              Result := not Terminated and not FSnapshotCancel;
            finally
              FLock.Release;
            end;
          end);
      try
        var NewRenderer := TPSPRendererSession.Create(Candidate, FRenderer, FResolution, FTextureScale, FTextureFilter);
        try
          var Frame: TEmulatorFrame;
          Candidate.Display.Render(Frame);
          Frame.FrameNumber := Candidate.FrameNumber;
          Frame.FramesPerSecond := 0;
          FLock.Acquire;
          try
            if Terminated or FSnapshotCancel then
              raise EAbort.Create('PSP snapshot loading cancelled');
          finally
            FLock.Release;
          end;
          var Previous := FConsole;
          var PreviousRenderer := Renderer;
          FConsole := Candidate;
          Candidate := nil;
          Renderer := NewRenderer;
          NewRenderer := nil;
          try
            PreviousRenderer.Free;
          finally
            Previous.Free;
          end;
          FLock.Acquire;
          try
            FFrame := Frame;
            FAvailable := True;
            FRendererStatus := Renderer.Status;
          finally
            FLock.Release;
          end;
        finally
          NewRenderer.Free;
        end;
      finally
        Candidate.Free;
      end;
    end
    else
    begin
      FConsole.SaveSnapshot(Path,
        function(Done, Total: UInt64): Boolean
        begin
          FLock.Acquire;
          try
            Result := not Terminated and not FSnapshotCancel;
          finally
            FLock.Release;
          end;
        end);
      try
        if Length(FFrame.Pixels) > 0 then
          SaveSnapshotPreview(Path, FFrame.Width, FFrame.Height, FFrame.Width, @FFrame.Pixels[0], FStorage);
      except
        // The machine state is already saved; optional artwork cannot undo it.
      end;
    end;
  except
    on E: EAbort do
      ;
    on E: Exception do
      Error := E.Message;
  end;
  FLock.Acquire;
  try
    FSnapshotError := Error;
    FSnapshotBusy := False;
    FSnapshotDone.SetEvent;
  finally
    FLock.Release;
  end;
end;

procedure TPSPWorker.Join;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

procedure TPSPWorker.Configure(const Input: TEmulatorInput; Paused: Boolean; AudioEnabled: Boolean; Volume: Single;
  Recompiler: Boolean);
begin
  FLock.Acquire;
  try
    FInput := Input;
    FRecompiler := Recompiler;
    FPaused := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := EnsureRange(Volume, 0.0, 1.0);
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TPSPWorker.RequestReset;
begin
  FLock.Acquire;
  try
    FReset := True;
    FAvailable := False;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TPSPWorker.Execute;
begin
  if Terminated then
    Exit;
{$IFDEF MSWINDOWS}
  var TimerSet := timeBeginPeriod(1) = TIMERR_NOERROR;
{$ENDIF}
  try
    try
      var Renderer := TPSPRendererSession.Create(FConsole, FRenderer, FResolution, FTextureScale, FTextureFilter);
      try
        FLock.Acquire;
        try
          FRendererStatus := Renderer.Status;
        finally
          FLock.Release;
        end;
        var AudioFailed := False;
        var WasEnabled := False;
        // Without sound, guest time follows the host clock from this point.
        var ClockHost := TStopwatch.GetTimeStamp;
        var ClockGuest := FConsole.Scheduler.Now;
        FRate.Reset(FConsole.FrameNumber, ClockHost);
        while not Terminated do
        begin
          var Paused, Reset: Boolean;
          var AudioEnabled: Boolean;
          var Volume: Single;
          var Input: TEmulatorInput;
          var Recompiler: Boolean;
          FLock.Acquire;
          try
            Recompiler := FRecompiler;
            Paused := FPaused;
            Reset := FReset;
            FReset := False;
            Input := FInput;
            AudioEnabled := FAudioEnabled;
            Volume := FVolume;
          finally
            FLock.Release;
          end;
          var Snapshot := ProcessSnapshot(Renderer);
          var Restart := Reset or Snapshot or Paused or (AudioEnabled <> WasEnabled);
          if Reset then
            FConsole.Reset;
          if Restart and (FAudio <> nil) and not AudioFailed then
            try
              FAudio.Clear;
            except
              AudioFailed := True;
            end;
          WasEnabled := AudioEnabled;
          if Restart then
          begin
            ClockHost := TStopwatch.GetTimeStamp;
            ClockGuest := FConsole.Scheduler.Now;
            FRate.Reset(FConsole.FrameNumber, ClockHost);
          end;
          // A dialog can pause the worker while reconstruction runs. Re-read
          // frontend controls before advancing the just-restored machine.
          if Snapshot then
            Continue;
          if Paused then
          begin
            FWake.WaitFor(20);
            Continue;
          end;
          // The sound queue is the real-time clock: a frame runs only when the
          // device has room for its samples.
          if AudioEnabled and not AudioFailed and (FAudio <> nil) then
            try
              if not FAudio.CanAdvance then
              begin
                FWake.WaitFor(1);
                Continue;
              end;
            except
              AudioFailed := True;
            end;
          if FConsole.Recompiler <> nil then
            FConsole.Recompiler.Enabled := Recompiler;
          FConsole.Input := Input;
          var Frame: TEmulatorFrame;
          FConsole.RunFrame(Frame);
          // Frames emulated per host second, not the PSP's nominal refresh rate.
          Frame.FramesPerSecond := FRate.Update(Frame.FrameNumber, TStopwatch.GetTimeStamp, TStopwatch.Frequency);
          if AudioEnabled and not AudioFailed then
            try
              if FAudio = nil then
                FAudio := TPSPAudioPlayback.Create;
              FAudio.Enqueue(FConsole.AudioSamples, Volume);
            except
              AudioFailed := True;
            end;
          FLock.Acquire;
          try
            FFrame := Frame;
            FAvailable := True;
            FRendererStatus := Renderer.Status;
          finally
            FLock.Release;
          end;
          if not AudioEnabled or AudioFailed then
          begin
            var Target := ClockHost + (FConsole.Scheduler.Now - ClockGuest) * TStopwatch.Frequency div 1000000000;
            // Input updates can wake the worker but must not accelerate guest time.
            while not Terminated do
            begin
              var Remaining := (Target - TStopwatch.GetTimeStamp) * 1000 div TStopwatch.Frequency;
              if Remaining <= 0 then
              begin
                if Remaining < -250 then
                begin
                  ClockHost := TStopwatch.GetTimeStamp;
                  ClockGuest := FConsole.Scheduler.Now;
                end;
                Break;
              end;
              FWake.WaitFor(Cardinal(Min(Int64(20), Remaining)));
            end;
          end;
        end;
      finally
        Renderer.Free;
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := E.ClassName + ': ' + E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
  finally
    FLock.Acquire;
    try
      if FSnapshotBusy then
      begin
        FSnapshotError := 'PSP emulation stopped before completing the snapshot';
        FSnapshotBusy := False;
        FSnapshotPending := False;
        FSnapshotDone.SetEvent;
      end;
    finally
      FLock.Release;
    end;
{$IFDEF MSWINDOWS}
    if TimerSet then
      timeEndPeriod(1);
{$ENDIF}
  end;
end;

function TPSPWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  FLock.Acquire;
  try
    Result := FAvailable;
    if Result then
    begin
      Frame := FFrame;
      FAvailable := False;
    end;
  finally
    FLock.Release;
  end;
end;

function TPSPWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

constructor TPSPCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName, ImageName: string);
begin
  inherited Create;
  var ActualStorage := Storage;
  if ActualStorage = nil then
    ActualStorage := TStorage.Default;
  FStorage := ActualStorage;
  var SourceName := ImageName;
  if SourceName = '' then
  begin
    SourceName := RomName;
    if SourceName.StartsWith('content://', True) then
      SourceName := ActualStorage.Describe(RomName).Name;
  end;
  if IsMediaArchive(SourceName) then
    FProgram := ReadPSPArchive(OpenMediaArchive(Stream, SourceName, ActualStorage), ActualStorage, True)
  else
  begin
    FProgram := TPSPProgram.Read(Stream);
    if (FProgram.BootPath <> '') and (RomName <> '') then
      FProgram.MediaPath := RomName;
  end;
  // Reject unsupported executables during loading, before starting a worker.
  var Probe := TPSPConsole.Create(FProgram, FStorage);
  Probe.Free;
  FConfigObject := TPSPConfig.Create(ActualStorage.ConfigFile('psp'), ActualStorage);
  FConfig := FConfigObject;
  FConfig.Load;
  FSnapshotDirectory := ActualStorage.GameSnapshots('psp', RomName, SnapshotIdentity(FProgram.Executable));
end;

destructor TPSPCoreAdapter.Destroy;
begin
  Stop;
  if FProgram.TemporaryMedia and (FStorage <> nil) and FStorage.Exists(FProgram.MediaPath) then
    FStorage.Delete(FProgram.MediaPath);
  inherited;
end;

procedure TPSPCoreAdapter.Configure;
begin
  if FWorker <> nil then
    FWorker.Configure(GetInputState, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume, FConfigObject.Recompiler);
end;

procedure TPSPCoreAdapter.Start;
begin
  if FWorker <> nil then
    Exit;
  FError := '';
  // The system settings the game reads (sceUtility, sceReg, sceImpose).
  PSPSettings.Language := FConfigObject.Language;
  PSPSettings.ButtonSwap := FConfigObject.ButtonSwap;
  PSPSettings.Nickname := FConfigObject.Nickname;
  FWorker := TPSPWorker.Create(FProgram, FStorage, FConfigObject.Renderer, FConfigObject.FontDirectory,
    FSnapshotDirectory, FConfigObject.Resolution, FConfigObject.TextureScale, FConfigObject.TextureFilter);
  try
    Configure;
    FWorker.Start;
  except
    FreeAndNil(FWorker);
    raise;
  end;
end;

procedure TPSPCoreAdapter.Stop;
begin
  if FWorker = nil then
    Exit;
  FWorker.Join;
  FRendererStatus := FWorker.RendererStatus;
  var Error := FWorker.TakeError;
  if Error <> '' then
    FError := Error;
  FreeAndNil(FWorker);
end;

procedure TPSPCoreAdapter.Pause;
begin
  FPaused := True;
  Configure;
end;

procedure TPSPCoreAdapter.Resume;
begin
  FPaused := False;
  Configure;
end;

procedure TPSPCoreAdapter.Reset;
begin
  FPaused := False;
  if (FWorker <> nil) and FWorker.Finished then
  begin
    Stop;
    Start;
  end
  else if FWorker <> nil then
    FWorker.RequestReset;
  Configure;
end;

procedure TPSPCoreAdapter.ClearInput;
begin
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  Configure;
end;

procedure TPSPCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = 0 then
    Exit;
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    if FConfigObject.Keys[Button] = Code then
      if Pressed then
        Include(FKeyboard.Buttons, Button)
      else
        Exclude(FKeyboard.Buttons, Button);
  Configure;
end;

procedure TPSPCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Default(TEmulatorInput);
  FGamepad.Buttons := Input.Buttons;
  FGamepad.Analog[0] := Input.Analog[0];
  Configure;
end;

function TPSPCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  Result.Buttons := Result.Buttons + FKeyboard.Buttons;
end;

function TPSPCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  Result := (FWorker <> nil) and FWorker.TryGetFrame(Frame);
end;

function TPSPCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FWorker <> nil) then
    Result := FWorker.TakeError;
end;

function TPSPWorker.RendererStatus: string;
begin
  FLock.Acquire;
  try
    Result := FRendererStatus;
  finally
    FLock.Release;
  end;
end;

function TPSPCoreAdapter.RendererStatus: string;
begin
  if FWorker <> nil then
    Result := FWorker.RendererStatus
  else
    Result := FRendererStatus;
end;

function TPSPCoreAdapter.GetName: string;
begin
  Result := 'Sony PSP';
end;

function TPSPCoreAdapter.GetSystemId: string;
begin
  Result := 'psp';
end;

function TPSPCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TPSPCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TPSPCoreAdapter.InsertCoin1;
begin
end;

procedure TPSPCoreAdapter.InsertCoin2;
begin
end;

procedure TPSPCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FWorker = nil then
    raise EInvalidOpException.Create('PSP is not running');
  FWorker.Snapshot(Name, False);
end;

procedure TPSPCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FWorker = nil then
    raise EInvalidOpException.Create('PSP is not running');
  FWorker.Snapshot(Name, True);
end;

function TPSPCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TPSPCoreAdapter.BeginSnapshot(const Name: string; Loading: Boolean);
begin
  if FWorker = nil then
    raise EInvalidOpException.Create('PSP is not running');
  FWorker.BeginSnapshot(Name, Loading);
end;

function TPSPCoreAdapter.SnapshotStatus(out Done, Total: UInt64; out Error: string): Boolean;
begin
  Done := 0;
  Total := 0;
  Error := '';
  Result := (FWorker <> nil) and FWorker.SnapshotStatus(Done, Total, Error);
end;

procedure TPSPCoreAdapter.CancelSnapshot;
begin
  if FWorker <> nil then
    FWorker.CancelSnapshot;
end;

function TPSPCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TPSPCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.
