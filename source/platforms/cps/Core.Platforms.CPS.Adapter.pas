unit Core.Platforms.CPS.Adapter;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.IniFiles,
  Core.Storage, Core.Emulation, CPS.Cartridge, CPS.RomSets, Core.Snapshots,
  Core.CD.Disc, PCM.Audio;

type
  TCPSKeys = array[TEmulatorButton] of UInt32;

  TCPSDIPs = array[0..2] of Integer;

  TCPSConfig = class(TEmulatorConfigBase)
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    DiscImage: string;
    MultigameBanks: string;
    DIPs: TCPSDIPs;
    Keys: array[0..3] of TCPSKeys;
    constructor Create(const FileName: string; const Storage: IStorage);
  end;

  // Keeps the hardware PCM stream continuous across video-frame boundaries.
  TCPSAudioBuffer = record
  private
    FPending: TArray<SmallInt>;
    FCount: Integer;
    FPrimed: Boolean;
  public
    procedure Clear(Audio: TPCMAudio);
    procedure Submit(Audio: TPCMAudio; const Samples: TArray<SmallInt>; const Format: TPCMAudioFormat);
  end;

  TCPSWorker = class(TThread)
  private
    FDisc: TCDDisc;
    FCart: TCPSCartridge;
    FStorage: IStorage;
    FIdentity: TBytes;
    FSavePath, FSnapshotDirectory, FCoreId: string;
    FSnapshots: TSnapshotQueue;
    FAudioEnabled: Boolean;
    FVolume: Single;
    FAudioError: string;
    FLock: TCriticalSection;
    FWake: TEvent;
    FInput: TEmulatorInput;
    FCoins: array[0..1] of Boolean;
    FPause, FReset, FAvailable: Boolean;
    FFrame: TEmulatorFrame;
    FError: string;
    procedure OrientFrame(var Frame: TEmulatorFrame);
  protected
    procedure Execute; override;
  public
    DIPOverride: TCPSDIPs;
    MultigameBanks: string;
    constructor Create(Cart: TCPSCartridge; const Storage: IStorage; const Identity: TBytes; const SavePath, SnapshotDirectory, CoreId: string; Disc: TCDDisc);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; Paused, Reset, AudioEnabled: Boolean; Volume: Single);
    procedure InsertCoin(Player: Integer);
    procedure Stop;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    procedure Snapshot(const Name: string; Loading: Boolean);
    function TakeAudioError: string;
    function TakeError: string;
  end;

  TCPSCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationVirtualControls, IEmulationAudioDiagnostics, IEmulationSnapshotLocation)
  private
    FDisc: TCDDisc;
    FCart: TCPSCartridge;
    FStorage: IStorage;
    FIdentity: TBytes;
    FSavePath, FSnapshotDirectory: string;
    FWorker: TCPSWorker;
    FConfig: IEmulatorConfig;
    FOptions: TCPSConfig;
    FKeyboard, FGamepad: TEmulatorInput;
    FPaused: Boolean;
    FError, FAudioError: string;
    procedure Configure;
  public
    procedure ApplyLiveSettings;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string);
    destructor Destroy; override;
    function GetSystemId: string;
    function GetName: string;
    function GetSupportsSnapshots: Boolean;
    function GetSnapshotDirectory: string;
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
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
    function GetVirtualButtons: TEmulatorButtons;
  end;

implementation

uses
  System.UITypes, System.Diagnostics, System.Math, CPS1.Console, CPS1.QSound,
  CPS1.Multigame, CPS2.Console, CPS3.Console, CPS.Video, Core.SavePaths,
  System.IOUtils;

const
  KeyNames: array[TEmulatorButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');

procedure TCPSCoreAdapter.ApplyLiveSettings;
begin
  Configure;
end;

procedure TCPSAudioBuffer.Clear(Audio: TPCMAudio);
begin
  FCount := 0;
  FPrimed := False;
  if Audio <> nil then
  begin
    Audio.Clear;
    Audio.SetPaused(True);
  end;
end;

procedure TCPSAudioBuffer.Submit(Audio: TPCMAudio; const Samples: TArray<SmallInt>; const Format: TPCMAudioFormat);
begin
  // Keep complete blocks and prime 46 ms before starting playback. Re-prime
  // after an underrun, pause, reset or state load instead of playing fragments.
  if FPrimed and (Audio.QueueState.QueuedBlocks = 0) then
  begin
    FPrimed := False;
    Audio.SetPaused(True);
  end;
  if Length(FPending) < FCount + Length(Samples) then
    SetLength(FPending, FCount + Length(Samples));
  if Length(Samples) > 0 then
    Move(Samples[0], FPending[FCount], Length(Samples) * SizeOf(SmallInt));
  Inc(FCount, Length(Samples));
  var BlockSamples := Format.BlockFrames * Format.Channels;
  if not FPrimed and (FCount < BlockSamples * 2) then
    Exit;
  var Used := 0;
  while (FCount - Used >= BlockSamples) and
    (Audio.QueueState.QueuedBlocks < Format.BlockCount) do
  begin
    Audio.Submit(Copy(FPending, Used, BlockSamples), Format.BlockFrames);
    Inc(Used, BlockSamples);
  end;
  Dec(FCount, Used);
  if FCount > 0 then
    Move(FPending[Used], FPending[0], FCount * SizeOf(SmallInt));
  if not FPrimed and (Used > 0) then
  begin
    Audio.SetPaused(False);
    FPrimed := True;
  end;
end;

procedure TCPSWorker.OrientFrame(var Frame: TEmulatorFrame);
begin
  var Rotation := FCart.RomSet.Rotation;
  if Rotation = 0 then
    Exit;

  var Source := Frame.Pixels;
  Frame.Pixels := nil;
  SetLength(Frame.Pixels, Length(Source));
  var W := Frame.Width;
  var H := Frame.Height;
  if (Rotation = 90) or (Rotation = 270) then
  begin
    Frame.Width := H;
    Frame.Height := W;
  end;
  for var Y := 0 to H - 1 do
    for var X := 0 to W - 1 do
      case Rotation of
        90:
          Frame.Pixels[X * H + H - 1 - Y] := Source[Y * W + X];
        180:
          Frame.Pixels[(H - 1 - Y) * W + W - 1 - X] := Source[Y * W + X];
        270:
          Frame.Pixels[(W - 1 - X) * H + Y] := Source[Y * W + X];
      end;
end;

constructor TCPSConfig.Create(const FileName: string; const Storage: IStorage);
const
  P1: TCPSKeys = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vk5, vkReturn, vkC, vkA, vkS, vkD, vkF2);
  P2: TCPSKeys = (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6, vkNumpad1, vkNumpad2, vk6, vkNumpad0, vkNumpad3, vkNumpad7, vkNumpad9, vkDecimal, 0);
begin
  inherited Create(FileName, Storage);
  Keys[0] := P1;
  Keys[1] := P2;
  for var i := 0 to 2 do
    DIPs[i] := -1;
end;

procedure TCPSConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  DiscImage := Ini.ReadString('CPS3', 'DiscImage', DiscImage);
  MultigameBanks := Ini.ReadString('CPS1', 'MultigameBanks', MultigameBanks);
  for var i := 0 to 2 do
  begin
    DIPs[i] := Ini.ReadInteger('CPS1', 'DIP' + Chr(Ord('A') + i), DIPs[i]);
    if (DIPs[i] < -1) or (DIPs[i] > 255) then
      DIPs[i] := -1;
  end;
  for var P := 0 to 3 do
  begin
    var Section := 'Keys';
    if P > 0 then
      Section := Section + IntToStr(P + 1);
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Keys[P, B] := ReadEmulatorKey(Ini, Section, KeyNames[B], Keys[P, B]);
  end;
end;

procedure TCPSConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('CPS3', 'DiscImage', DiscImage);
  Ini.WriteString('CPS1', 'MultigameBanks', MultigameBanks);
  for var i := 0 to 2 do
    Ini.WriteInteger('CPS1', 'DIP' + Chr(Ord('A') + i), DIPs[i]);
  for var P := 0 to 3 do
  begin
    var Section := 'Keys';
    if P > 0 then
      Section := Section + IntToStr(P + 1);
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Ini.WriteInteger(Section, KeyNames[B], Keys[P, B]);
  end;
end;

constructor TCPSWorker.Create(Cart: TCPSCartridge; const Storage: IStorage; const Identity: TBytes; const SavePath, SnapshotDirectory, CoreId: string; Disc: TCDDisc);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCart := Cart;
  FDisc := Disc;
  for var i := 0 to 2 do
    DIPOverride[i] := -1;
  FStorage := Storage;
  FIdentity := Identity;
  FSavePath := SavePath;
  FSnapshotDirectory := SnapshotDirectory;
  FCoreId := CoreId;
  FSnapshots := TSnapshotQueue.Create;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
end;

destructor TCPSWorker.Destroy;
begin
  Stop;
  FSnapshots.Free;
  FWake.Free;
  FLock.Free;
  inherited;
end;

procedure TCPSWorker.Stop;
begin
  Terminate;
  FWake.SetEvent;
  WaitFor;
end;

procedure TCPSWorker.Configure(const Input: TEmulatorInput; Paused, Reset, AudioEnabled: Boolean; Volume: Single);
begin
  FLock.Acquire;
  try
    FInput := Input;
    FPause := Paused;
    FReset := FReset or Reset;
    FAudioEnabled := AudioEnabled;
    FVolume := Volume;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TCPSWorker.InsertCoin(Player: Integer);
begin
  FLock.Acquire;
  try
    FCoins[Player - 1] := True;
  finally
    FLock.Release;
  end;
end;

function TCPSWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TCPSWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

procedure TCPSWorker.Snapshot(const Name: string; Loading: Boolean);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, Loading);
end;

function TCPSWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

procedure TCPSWorker.Execute;
var
  C12: TCPS1Console;
  C3: TCPS3Console;
  Audio: TPCMAudio;
  LastBattery: TBytes;
  LastBatteryRevision: UInt64;
  AudioFailed: Boolean;
  AudioBuffer: TCPSAudioBuffer;

  procedure SaveBattery;
  begin
    if (C12 = nil) and (C3 = nil) then
      Exit;

    if (C3 <> nil) and (C3.BatteryRevision = LastBatteryRevision) then
      Exit;

    var Data: TBytes;
    if C12 <> nil then
      Data := C12.Battery
    else
      Data := C3.Battery;
    if Length(Data) = 0 then
      Exit;

    if (Length(Data) = Length(LastBattery)) and CompareMem(@Data[0], @LastBattery[0], Length(Data)) then
    begin
      if C3 <> nil then
        LastBatteryRevision := C3.BatteryRevision;
      Exit;
    end;

    var Stream := TMemoryStream.Create;
    try
      Stream.WriteBuffer(Data[0], Length(Data));
      SaveStreamAtomically(Stream, FSavePath, FStorage);
      LastBattery := Copy(Data);
      if C3 <> nil then
        LastBatteryRevision := C3.BatteryRevision;
    finally
      Stream.Free;
    end;
  end;

begin
  C12 := nil;
  C3 := nil;
  Audio := nil;
  AudioFailed := False;
  AudioBuffer := Default(TCPSAudioBuffer);
  LastBatteryRevision := 0;
  try
    try
      case FCart.RomSet.Generation of
        TCPSGeneration.CPS1:
          C12 := CreateCPS1Console(FCart);
        TCPSGeneration.CPS2:
          C12 := TCPS2Console.Create(FCart);
        TCPSGeneration.CPS3:
          C3 := TCPS3Console.Create(FCart, FDisc);
      end;
      if C12 <> nil then
      begin
        if (C12 is TCPSMultigameConsole) and (MultigameBanks <> '') then
        begin
          var Banks := MultigameBanks.Split([',']);
          if not (Length(Banks) in [4, 5]) then
            raise EArgumentException.Create('CPS1 MultigameBanks needs program,graphics,audio,sample[,graphicsHalf]');

          var Half := 0;
          if Length(Banks) = 5 then
            Half := StrToInt(Banks[4]);
          TCPSMultigameConsole(C12).SelectBanks(StrToInt(Banks[0]), StrToInt(Banks[1]), StrToInt(Banks[2]), StrToInt(Banks[3]), Half);
        end;
        for var i := 0 to 2 do
          if DIPOverride[i] >= 0 then
            C12.DIP[i] := Byte(DIPOverride[i]);
      end;
      if FStorage.Exists(FSavePath) then
      begin
        // Persistent SIMMs can exceed the user's ROM-file size limit.
        // Open the save as state data and bound it independently.
        var SaveStream := FStorage.OpenRead(FSavePath);
        try
          if (SaveStream.Size <= 0) or (SaveStream.Size > 128 * 1024 * 1024) then
            raise EReadError.Create('Invalid CPS battery size');

          SetLength(LastBattery, SaveStream.Size);
          SaveStream.ReadBuffer(LastBattery[0], Length(LastBattery));
        finally
          SaveStream.Free;
        end;
        if C12 <> nil then
          C12.LoadBattery(LastBattery)
        else
          C3.LoadBattery(LastBattery);
      end;
      var Format: TPCMAudioFormat;
      Format.SampleRate := 44100;
      Format.Channels := 2;
      Format.BlockFrames := 1024;
      Format.BlockCount := 4;
      var FPS := CPS_FPS;
      if C3 <> nil then
        FPS := CPS3_FPS;
      var Deadline := TStopwatch.GetTimeStamp;
      while not Terminated do
      begin
        FSnapshots.Process(
          procedure(const Name: string; Loading: Boolean)
          begin
            var Path := ResolveSnapshotPath(FSnapshotDirectory, Name);
            var Transfer: TStateTransfer :=
              procedure(State: TStateArchive)
              begin
                if C12 <> nil then
                  C12.SerializeState(State)
                else
                  C3.SerializeState(State);
              end;
            if Loading then
            begin
              LoadCoreSnapshot(Path, FCoreId, FIdentity, Transfer, FStorage);
              AudioBuffer.Clear(Audio);
              var Restored: TEmulatorFrame;
              Restored.Width := CPS_WIDTH;
              Restored.Height := CPS_HEIGHT;
              Restored.FramesPerSecond := FPS;
              if C12 <> nil then
              begin
                Restored.Pixels := Copy(C12.Video.Pixels);
                Restored.FrameNumber := C12.FrameNumber;
              end
              else
              begin
                Restored.Pixels := Copy(C3.Pixels);
                Restored.FrameNumber := C3.FrameNumber;
              end;
              OrientFrame(Restored);
              FLock.Acquire;
              try
                FFrame := Restored;
                FAvailable := True;
              finally
                FLock.Release;
              end;
            end
            else
            begin
              SaveCoreSnapshot(Path, FCoreId, FIdentity, Transfer, FStorage);
              var Preview: TEmulatorFrame;
              Preview.Width := CPS_WIDTH;
              Preview.Height := CPS_HEIGHT;
              if C12 <> nil then
                Preview.Pixels := Copy(C12.Video.Pixels)
              else
                Preview.Pixels := Copy(C3.Pixels);
              OrientFrame(Preview);
              SaveSnapshotPreview(Path, Preview.Width, Preview.Height, Preview.Width, @Preview.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
          end);
        FLock.Acquire;
        var Enabled := FAudioEnabled;
        var Volume := FVolume;
        var Input := FInput;
        var Paused := FPause;
        var Reset := FReset;
        var Coin1 := FCoins[0];
        var Coin2 := FCoins[1];
        FReset := False;
        FCoins[0] := False;
        FCoins[1] := False;
        FLock.Release;
        if Reset then
        begin
          if C12 <> nil then
            C12.Reset
          else
            C3.Reset;
          AudioBuffer.Clear(Audio);
        end;
        if C12 <> nil then
        begin
          C12.SetInput(Input);
          if Coin1 then
            C12.InsertCoin(1);
          if Coin2 then
            C12.InsertCoin(2);
        end
        else
        begin
          C3.SetInput(Input);
          if Coin1 then
            C3.InsertCoin(1);
          if Coin2 then
            C3.InsertCoin(2);
        end;

        if Paused then
        begin
          AudioBuffer.Clear(Audio);
          FWake.WaitFor(20);
          Deadline := TStopwatch.GetTimeStamp;
          Continue;
        end;

        var Frame: TEmulatorFrame;
        Frame.Width := CPS_WIDTH;
        Frame.Height := CPS_HEIGHT;
        Frame.FramesPerSecond := FPS;
        if C12 <> nil then
        begin
          C12.RunFrame;
          Frame.Pixels := Copy(C12.Video.Pixels);
          Frame.FrameNumber := C12.FrameNumber;
        end
        else
        begin
          C3.RunFrame;
          Frame.Pixels := Copy(C3.Pixels);
          Frame.FrameNumber := C3.FrameNumber;
        end;
        OrientFrame(Frame);
        FLock.Acquire;
        try
          FFrame := Frame;
          FAvailable := True;
        finally
          FLock.Release;
        end;
        if Enabled and not AudioFailed then
        try
          if Audio = nil then
          begin
            Audio := TPCMAudio.Create(Format);
            Audio.SetPaused(True);
          end;
          var Samples: TArray<SmallInt>;
          if C12 <> nil then
            Samples := Copy(C12.Samples)
          else
            Samples := Copy(C3.Sound.Samples);
          for var i := 0 to High(Samples) do
            Samples[i] := Round(Samples[i] * Volume);
          AudioBuffer.Submit(Audio, Samples, Format);
          if Audio.Error <> '' then
            raise EInOutError.Create(Audio.Error);
        except
          on E: Exception do
          begin
            FLock.Acquire;
            try
              FAudioError := 'CPS audio: ' + E.Message;
            finally
              FLock.Release;
            end;
            FreeAndNil(Audio);
            AudioFailed := True;
          end;
        end
        else if not Enabled then
        begin
          AudioBuffer.Clear(Audio);
          AudioFailed := False;
        end;
        if Frame.FrameNumber mod 120 = 0 then
          SaveBattery;
        Inc(Deadline, Round(TStopwatch.Frequency / FPS));
        var Now := TStopwatch.GetTimeStamp;
        if Now - Deadline > TStopwatch.Frequency div 4 then
          Deadline := Now;
        // Configure wakes this event for input updates too. A wake is not a
        // frame tick: keep waiting until the wall-clock deadline has arrived.
        while not Terminated and (Now < Deadline) do
        begin
          FWake.WaitFor(Max(1, Integer((Deadline - Now) * 1000 div TStopwatch.Frequency)));
          Now := TStopwatch.GetTimeStamp;
        end;
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
    try
      try
        SaveBattery;
      except
        on E: Exception do
        begin
          FLock.Acquire;
          try
            FError := 'CPS save: ' + E.Message;
          finally
            FLock.Release;
          end;
        end;
      end;
    finally
      Audio.Free;
      C3.Free;
      C12.Free;
    end;
  end;
end;

constructor TCPSCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
begin
  inherited Create;
  FCart := TCPSCartridge.Create(Stream, RomName);

  var S := Storage;
  if S = nil then
    S := TStorage.Default;
  FStorage := S;
  FIdentity := FCart.Identity;

  FOptions := TCPSConfig.Create(S.ConfigFile(GetSystemId), S);
  FConfig := FOptions;
  FConfig.Load;
  if (FCart.RomSet.Generation = TCPSGeneration.CPS3) and not FCart.HasRegion('simm1.0') then
  begin
    var DiscName := FCart.RomSet.DiscName;
    if DiscName = '' then
      raise ECPSRom.Create('CPS3 disc metadata missing for ' + FCart.RomSet.Name);

    var Location := FOptions.DiscImage;
    if Location = '' then
    begin
      var NativeName := RomName.Replace('/', PathDelim);
      var Parent := ExtractFilePath(NativeName);
      var Folder := TPath.Combine(Parent, ChangeFileExt(ExtractFileName(NativeName), ''));
      for var Extension in ['.chd', '.cue', '.iso'] do
      begin
        var Candidate := TPath.Combine(Folder, DiscName + Extension);
        if S.Exists(Candidate) then
        begin
          Location := Candidate;
          Break;
        end;

        Candidate := TPath.Combine(Parent, DiscName + Extension);
        if S.Exists(Candidate) then
        begin
          Location := Candidate;
          Break;
        end;
      end;
    end;
    if Location = '' then
      raise ECPSRom.Create('CPS3 CD image missing: place ' + DiscName + '.chd beside the BIOS ZIP or in its sibling game folder, or set [CPS3] DiscImage in the CPS3 configuration.');

    var CDStream := S.OpenRead(Location);
    try
      FDisc := TCDDisc.Create(CDStream, S, Location);
    finally
      CDStream.Free;
    end;
    var DiscIdentity := FDisc.Identity;
    var Offset := Length(FIdentity);
    SetLength(FIdentity, Offset + Length(DiscIdentity));
    Move(DiscIdentity[0], FIdentity[Offset], Length(DiscIdentity));
  end;
  var IdentityHash := SnapshotIdentity(FIdentity);
  FSavePath := S.GameSave(GetSystemId, RomName, IdentityHash);
  FSnapshotDirectory := S.GameSnapshots(GetSystemId, RomName, IdentityHash);
end;

destructor TCPSCoreAdapter.Destroy;
begin
  Stop;
  FDisc.Free;
  FCart.Free;
  inherited;
end;

procedure TCPSCoreAdapter.Configure;
begin
  if FWorker <> nil then
    FWorker.Configure(GetInputState, FPaused, False, FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TCPSCoreAdapter.Start;
begin
  if FWorker <> nil then
    Exit;

  // Continue Game requests Pause before starting the worker and restoring state.
  // Preserve that request; only Resume should release an existing pause.
  FWorker := TCPSWorker.Create(FCart, FStorage, FIdentity, FSavePath, FSnapshotDirectory, GetSystemId, FDisc);
  FWorker.DIPOverride := FOptions.DIPs;
  FWorker.MultigameBanks := FOptions.MultigameBanks;
  Configure;
  FWorker.Start;
end;

procedure TCPSCoreAdapter.Stop;
begin
  if FWorker = nil then
    Exit;

  FWorker.Stop;
  var AudioError := FWorker.TakeAudioError;
  if AudioError <> '' then
    FAudioError := AudioError;
  var Error := FWorker.TakeError;
  if Error <> '' then
    FError := Error;
  FreeAndNil(FWorker);
end;

procedure TCPSCoreAdapter.Pause;
begin
  FPaused := True;
  Configure;
end;

procedure TCPSCoreAdapter.Resume;
begin
  FPaused := False;
  Configure;
end;

procedure TCPSCoreAdapter.Reset;
begin
  if FWorker <> nil then
    FWorker.Configure(GetInputState, FPaused, True, FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TCPSCoreAdapter.InsertCoin1;
begin
  if FWorker <> nil then
    FWorker.InsertCoin(1);
end;

procedure TCPSCoreAdapter.InsertCoin2;
begin
  if FWorker <> nil then
    FWorker.InsertCoin(2);
end;

procedure TCPSCoreAdapter.ClearInput;
begin
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  Configure;
end;

procedure TCPSCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    if (Code <> 0) and (Code = FOptions.Keys[0, B]) then
      if Pressed then
        Include(FKeyboard.Buttons, B)
      else
        Exclude(FKeyboard.Buttons, B);
    if (Code <> 0) and (Code = FOptions.Keys[1, B]) then
      if Pressed then
        Include(FKeyboard.Buttons2, B)
      else
        Exclude(FKeyboard.Buttons2, B);
    if (Code <> 0) and (Code = FOptions.Keys[2, B]) then
      if Pressed then
        Include(FKeyboard.Buttons3, B)
      else
        Exclude(FKeyboard.Buttons3, B);
    if (Code <> 0) and (Code = FOptions.Keys[3, B]) then
      if Pressed then
        Include(FKeyboard.Buttons4, B)
      else
        Exclude(FKeyboard.Buttons4, B);
  end;
  Configure;
end;

procedure TCPSCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input;
  Configure;
end;

function TCPSCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  Result.Buttons := Result.Buttons + FKeyboard.Buttons;
  Result.Buttons2 := Result.Buttons2 + FKeyboard.Buttons2;
  Result.Buttons3 := Result.Buttons3 + FKeyboard.Buttons3;
  Result.Buttons4 := Result.Buttons4 + FKeyboard.Buttons4;
end;

function TCPSCoreAdapter.GetSystemId: string;
begin
  Result := 'cps' + IntToStr(Ord(FCart.RomSet.Generation));
end;

function TCPSCoreAdapter.GetName: string;
begin
  Result := 'Capcom CPS-' + IntToStr(Ord(FCart.RomSet.Generation));
end;

function TCPSCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TCPSCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

function TCPSCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := True;
end;

function TCPSCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

function TCPSCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  Configure;
  Result := (FWorker <> nil) and FWorker.TryGetFrame(Frame);
end;

function TCPSCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FWorker <> nil) then
    Result := FWorker.TakeError;
end;

function TCPSCoreAdapter.TakeAudioError: string;
begin
  Result := FAudioError;
  FAudioError := '';
  if (Result = '') and (FWorker <> nil) then
    Result := FWorker.TakeAudioError;
end;

function TCPSCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TCPSCoreAdapter.GetVirtualButtons: TEmulatorButtons;
begin
  Result := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right,
      TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z,
      TEmulatorButton.Select, TEmulatorButton.Start, TEmulatorButton.Mode];
end;

procedure TCPSCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FWorker = nil then
    raise EInvalidOpException.Create('CPS core is stopped');

  FWorker.Snapshot(Name, False);
end;

procedure TCPSCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FWorker = nil then
    raise EInvalidOpException.Create('CPS core is stopped');

  FWorker.Snapshot(Name, True);
end;

end.

