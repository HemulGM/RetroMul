unit Core.Platforms.System32.Adapter;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.IniFiles,
  System.Types, Core.Storage, Core.Emulation, Core.InputConfig, S32.Cartridge,
  S32.RomSets, Core.Snapshots, Core.CD.Disc, PCM.Audio;

type
  TS32Keys = array[TEmulatorButton] of UInt32;

  TS32DIPs = array[0..1] of Integer;

  TS32Config = class(TEmulatorConfigBase)
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    DIPs: TS32DIPs;
    DiscImage: string;
    CDPrinterReady: Boolean;
    Keys: array[0..3] of TS32Keys;
    constructor Create(const FileName: string; const Storage: IStorage);
  end;

  // Keeps the hardware PCM stream continuous across video-frame boundaries.
  TS32AudioBuffer = record
  private
    FPending: TArray<SmallInt>;
    FCount: Integer;
    FPrimed: Boolean;
  public
    procedure Clear(Audio: TPCMAudio);
    procedure Submit(Audio: TPCMAudio; const Samples: TArray<SmallInt>; const Format: TPCMAudioFormat);
  end;

  TS32Worker = class(TThread)
  private
    FCart: TS32Cartridge;
    FDisc: TCDDisc;
    FStorage: IStorage;
    FIdentity: TBytes;
    FSavePath, FSnapshotDirectory, FCoreId: string;
    FSnapshots: TSnapshotQueue;
    FAudioEnabled: Boolean;
    FCDPrinterReady: Boolean;
    FVolume: Single;
    FAudioError: string;
    FLock: TCriticalSection;
    FWake: TEvent;
    FInput: TEmulatorInput;
    FCoins: array[0..1] of Boolean;
    FPause, FReset, FAvailable: Boolean;
    FFrame: TEmulatorFrame;
    FRegions: TArray<TRect>;
    FError: string;
    procedure OrientFrame(var Frame: TEmulatorFrame);
  protected
    procedure Execute; override;
  public
    DIPOverride: TS32DIPs;
    constructor Create(Cart: TS32Cartridge; const Storage: IStorage; const Identity: TBytes; const SavePath, SnapshotDirectory, CoreId: string; Disc: TCDDisc = nil);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; Paused, Reset, AudioEnabled: Boolean; Volume: Single);
    procedure InsertCoin(Player: Integer);
    procedure Stop;
    function TryGetFrame(out Frame: TEmulatorFrame; out Regions: TArray<TRect>): Boolean;
    procedure Snapshot(const Name: string; Loading: Boolean);
    function TakeAudioError: string;
    function TakeError: string;
  end;

  TS32CoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationVirtualControls, IEmulationInputPorts, IEmulationAudioDiagnostics, IEmulationSnapshotLocation, IEmulationPointerInput, IEmulationMouseInput, IEmulationVideoRegions)
  private
    FCart: TS32Cartridge;
    FDisc: TCDDisc;
    FStorage: IStorage;
    FIdentity: TBytes;
    FSavePath, FSnapshotDirectory: string;
    FWorker: TS32Worker;
    FConfig: IEmulatorConfig;
    FOptions: TS32Config;
    FKeyboard, FGamepad: TEmulatorInput;
    FPorts: TCoreInputPorts;
    FPaused: Boolean;
    FError, FAudioError: string;
    FPointerX, FPointerY, FPictureWidth: Integer;
    FPointerValid, FPointerSeen: Boolean;
    FMouseButtons: Byte;
    FRegions: TArray<TRect>;
    procedure Configure;
  public
    procedure ApplyLiveSettings;
    function GetVideoRegions: TArray<TRect>;
    function GetUsesPointer: Boolean;
    procedure SetPointer(X, Y: Integer; Valid: Boolean);
    procedure SendMouseDelta(DX, DY: Integer; Buttons: Byte);
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
    procedure ApplyInputPorts(const Ports: TCoreInputPorts);
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
  System.UITypes, System.Diagnostics, System.Math, S32.Console, S32.Video,
  Core.SavePaths, System.IOUtils;

const
  KeyNames: array[TEmulatorButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');

procedure TS32CoreAdapter.ApplyLiveSettings;
begin
  Configure;
end;

procedure TS32AudioBuffer.Clear(Audio: TPCMAudio);
begin
  FCount := 0;
  FPrimed := False;
  if Audio <> nil then
  begin
    Audio.Clear;
    Audio.SetPaused(True);
  end;
end;

procedure TS32AudioBuffer.Submit(Audio: TPCMAudio; const Samples: TArray<SmallInt>; const Format: TPCMAudioFormat);
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

procedure TS32Worker.OrientFrame(var Frame: TEmulatorFrame);
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

constructor TS32Config.Create(const FileName: string; const Storage: IStorage);
const
  P1: TS32Keys = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vk5, vkReturn, vkC, vkA, vkS, vkD, vkF2);
  P2: TS32Keys = (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6, vkNumpad1, vkNumpad2, vk6, vkNumpad0, vkNumpad3, vkNumpad7, vkNumpad9, vkDecimal, 0);
begin
  inherited Create(FileName, Storage);
  CDPrinterReady := True;
  Keys[0] := P1;
  Keys[1] := P2;
  for var i := Low(DIPs) to High(DIPs) do
    DIPs[i] := -1;
end;

procedure TS32Config.LoadCoreSettings(Ini: TCustomIniFile);
begin
  DiscImage := Ini.ReadString('System32', 'DiscImage', DiscImage);
  CDPrinterReady := Ini.ReadBool('System32', 'CDPrinterReady', True);
  for var i := Low(DIPs) to High(DIPs) do
  begin
    DIPs[i] := Ini.ReadInteger('System32', 'DIP' + Chr(Ord('A') + i), DIPs[i]);
    if (DIPs[i] < -1) or (DIPs[i] > 15) then
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

procedure TS32Config.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('System32', 'DiscImage', DiscImage);
  Ini.WriteBool('System32', 'CDPrinterReady', CDPrinterReady);
  for var i := Low(DIPs) to High(DIPs) do
    Ini.WriteInteger('System32', 'DIP' + Chr(Ord('A') + i), DIPs[i]);
  for var P := 0 to 3 do
  begin
    var Section := 'Keys';
    if P > 0 then
      Section := Section + IntToStr(P + 1);
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Ini.WriteInteger(Section, KeyNames[B], Keys[P, B]);
  end;
end;

constructor TS32Worker.Create(Cart: TS32Cartridge; const Storage: IStorage; const Identity: TBytes; const SavePath, SnapshotDirectory, CoreId: string; Disc: TCDDisc);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCart := Cart;
  FDisc := Disc;
  FCDPrinterReady := True;
  for var i := Low(DIPOverride) to High(DIPOverride) do
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

destructor TS32Worker.Destroy;
begin
  Stop;
  FSnapshots.Free;
  FWake.Free;
  FLock.Free;
  inherited;
end;

procedure TS32Worker.Stop;
begin
  Terminate;
  FWake.SetEvent;
  WaitFor;
end;

procedure TS32Worker.Configure(const Input: TEmulatorInput; Paused, Reset, AudioEnabled: Boolean; Volume: Single);
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

procedure TS32Worker.InsertCoin(Player: Integer);
begin
  FLock.Acquire;
  try
    FCoins[Player - 1] := True;
  finally
    FLock.Release;
  end;
end;

function TS32Worker.TryGetFrame(out Frame: TEmulatorFrame; out Regions: TArray<TRect>): Boolean;
begin
  FLock.Acquire;
  try
    Result := FAvailable;
    if Result then
    begin
      Frame := FFrame;
      Regions := Copy(FRegions);
      FAvailable := False;
    end;
  finally
    FLock.Release;
  end;
end;

function TS32Worker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

procedure TS32Worker.Snapshot(const Name: string; Loading: Boolean);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, Loading);
end;

function TS32Worker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

procedure TS32Worker.Execute;
var
  Console: TS32Console;
  Audio: TPCMAudio;
  AudioBuffer: TS32AudioBuffer;
  AudioFailed: Boolean;
  LastBattery: TBytes;
  Publish: TProc;

  procedure SaveBattery;
  begin
    if Console = nil then
      Exit;
    var Data := Console.Battery;
    if Length(Data) = 0 then
      Exit;
    if (Length(Data) = Length(LastBattery)) and CompareMem(@Data[0], @LastBattery[0], Length(Data)) then
      Exit;
    var Stream := TBytesStream.Create(Data);
    try
      FStorage.WriteAtomic(FSavePath, Stream);
      LastBattery := Data;
    finally
      Stream.Free;
    end;
  end;

begin
  Console := nil;
  Audio := nil;
  AudioFailed := False;
  AudioBuffer := Default(TS32AudioBuffer);
  Publish :=
    procedure
    begin
      var Frame: TEmulatorFrame;
      Frame.Width := Console.FrameWidth;
      Frame.Height := S32_HEIGHT;
      Frame.FramesPerSecond := S32_FPS;
      Frame.Pixels := Copy(Console.FramePixels);
      Frame.FrameNumber := Console.FrameNumber;
      OrientFrame(Frame);
      FLock.Acquire;
      try
        FFrame := Frame;
        FRegions := [Rect(0, 0, Console.Video.Width, S32_HEIGHT)];
        if Console.SubBoard <> nil then
          FRegions := FRegions + [Rect(Console.Video.Width, 0, Frame.Width, S32_HEIGHT)];
        FAvailable := True;
      finally
        FLock.Release;
      end;
    end;

  try
    try
      Console := TS32Console.Create(FCart, 0, FDisc);
      Console.CDPrinterReady := FCDPrinterReady;
      for var I := Low(DIPOverride) to High(DIPOverride) do
        if DIPOverride[I] >= 0 then
          Console.DIP[I] := Byte(DIPOverride[I]);
      if FStorage.Exists(FSavePath) then
      begin
        LastBattery := FStorage.ReadBytes(FSavePath);
        Console.LoadBattery(LastBattery);
      end;
      var Format: TPCMAudioFormat;
      Format.SampleRate := 44100;
      Format.Channels := 2;
      Format.BlockFrames := 1024;
      Format.BlockCount := 4;
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
                Console.SerializeState(State);
              end;
            if Loading then
            begin
              LoadCoreSnapshot(Path, FCoreId, FIdentity, Transfer, FStorage);
              AudioBuffer.Clear(Audio);
              Publish;
            end
            else
            begin
              SaveCoreSnapshot(Path, FCoreId, FIdentity, Transfer, FStorage);
              var Preview: TEmulatorFrame;
              Preview.Width := Console.FrameWidth;
              Preview.Height := S32_HEIGHT;
              Preview.Pixels := Copy(Console.FramePixels);
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
          Console.Reset;
          AudioBuffer.Clear(Audio);
        end;
        Console.SetInput(Input);
        if Coin1 then
          Console.InsertCoin(1);
        if Coin2 then
          Console.InsertCoin(2);
        if Paused then
        begin
          AudioBuffer.Clear(Audio);
          FWake.WaitFor(20);
          Deadline := TStopwatch.GetTimeStamp;
          Continue;
        end;
        Console.RunFrame;
        Publish;
        if Enabled and not AudioFailed then
        try
          if Audio = nil then
          begin
            Audio := TPCMAudio.Create(Format);
            Audio.SetPaused(True);
          end;
          var Samples := Copy(Console.AudioSamples);
          for var I := 0 to High(Samples) do
            Samples[I] := Round(Samples[I] * Volume);
          AudioBuffer.Submit(Audio, Samples, Format);
          if Audio.Error <> '' then
            raise EInOutError.Create(Audio.Error);
        except
          on E: Exception do
          begin
            FLock.Acquire;
            try
              FAudioError := 'System 32 audio: ' + E.Message;
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
        if Console.FrameNumber mod 120 = 0 then
          SaveBattery;
        Inc(Deadline, Round(TStopwatch.Frequency / S32_FPS));
        var Now := TStopwatch.GetTimeStamp;
        if Now - Deadline > TStopwatch.Frequency div 4 then
          Deadline := Now;
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
            FError := 'System 32 save: ' + E.Message;
          finally
            FLock.Release;
          end;
        end;
      end;
    finally
      Audio.Free;
      Console.Free;
    end;
  end;
end;

constructor TS32CoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
begin
  inherited Create;
  FCart := TS32Cartridge.Create(Stream, RomName, Storage);
  FPictureWidth := 320;

  var S := Storage;
  if S = nil then
    S := TStorage.Default;
  FStorage := S;
  FIdentity := FCart.Identity;

  FOptions := TS32Config.Create(S.ConfigFile(GetSystemId), S);
  FConfig := FOptions;
  FConfig.Load;
  FPorts := LoadCoreInputPorts(S, GetSystemId, GetConfig.FileName);
  if FCart.RomSet.Name.StartsWith('kokoro') then
  begin
    var Location := FOptions.DiscImage;
    if Location = '' then
    begin
      var DiscName := 'kokoroj';
      if FCart.RomSet.Name = 'kokoroj2' then
        DiscName := 'cdp-00146';
      var Parent := ExtractFilePath(RomName.Replace('/', PathDelim));
      for var Extension in ['.chd', '.cue', '.iso'] do
      begin
        var Candidate := TPath.Combine(TPath.Combine(Parent, FCart.RomSet.Name), DiscName + Extension);
        if not S.Exists(Candidate) then
          Candidate := TPath.Combine(Parent, DiscName + Extension);
        if S.Exists(Candidate) then
        begin
          Location := Candidate;
          Break;
        end;
        if RomName.StartsWith('content://', True) then
        begin
          Candidate := CDSibling(S, RomName, DiscName + Extension);
          if Candidate <> '' then
            if S.Exists(Candidate) then
            begin
              Location := Candidate;
              Break;
            end;
        end;
      end;
    end;
    if Location <> '' then
    begin
      var CDStream := S.OpenRead(Location);
      try
        FDisc := TCDDisc.Create(CDStream, S, Location);
      finally
        CDStream.Free;
      end;
      FIdentity := FIdentity + FDisc.Identity;
    end;
  end;
  var IdentityHash := SnapshotIdentity(FIdentity);
  FSavePath := S.GameSave(GetSystemId, RomName, IdentityHash);
  FSnapshotDirectory := S.GameSnapshots(GetSystemId, RomName, IdentityHash);
end;

destructor TS32CoreAdapter.Destroy;
begin
  Stop;
  FDisc.Free;
  FCart.Free;
  inherited;
end;

procedure TS32CoreAdapter.Configure;
begin
  if FWorker <> nil then
    FWorker.Configure(GetInputState, FPaused, False, FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TS32CoreAdapter.Start;
begin
  if FWorker <> nil then
    Exit;

  // Continue Game requests Pause before starting the worker and restoring state.
  // Preserve that request; only Resume should release an existing pause.
  FWorker := TS32Worker.Create(FCart, FStorage, FIdentity, FSavePath, FSnapshotDirectory, GetSystemId, FDisc);
  FWorker.FCDPrinterReady := FOptions.CDPrinterReady;
  FWorker.DIPOverride := FOptions.DIPs;
  Configure;
  FWorker.Start;
end;

procedure TS32CoreAdapter.Stop;
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

procedure TS32CoreAdapter.Pause;
begin
  FPaused := True;
  Configure;
end;

procedure TS32CoreAdapter.Resume;
begin
  FPaused := False;
  Configure;
end;

procedure TS32CoreAdapter.Reset;
begin
  if FWorker <> nil then
    FWorker.Configure(GetInputState, FPaused, True, FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TS32CoreAdapter.InsertCoin1;
begin
  if FWorker <> nil then
    FWorker.InsertCoin(1);
end;

procedure TS32CoreAdapter.InsertCoin2;
begin
  if FWorker <> nil then
    FWorker.InsertCoin(2);
end;

procedure TS32CoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  FPorts := Ports;
  for var I := 0 to 3 do
    FPorts.Devices[I] := FPorts.Devices[I].Trim.ToLower;
  ClearInput;
end;

procedure TS32CoreAdapter.ClearInput;
begin
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  FPointerValid := False;
  FPointerSeen := False;
  FMouseButtons := 0;
  Configure;
end;

procedure TS32CoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    if (Code <> 0) and (Code = FOptions.Keys[0, B]) then
    begin
      if Pressed and GetUsesPointer and (B in [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right]) then
        FPointerValid := False;
      if Pressed then
        Include(FKeyboard.Buttons, B)
      else
        Exclude(FKeyboard.Buttons, B);
    end;
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

procedure TS32CoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  if GetUsesPointer then
    if Input.Analog[0].Valid and ((Input.Analog[0].X <> FGamepad.Analog[0].X) or
      (Input.Analog[0].Y <> FGamepad.Analog[0].Y) or not FGamepad.Analog[0].Valid) then
      FPointerValid := False;
  FGamepad := Input;
  Configure;
end;

function TS32CoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  if FPorts.KeyboardEnabled then
  begin
    Result.Buttons := Result.Buttons + FKeyboard.Buttons;
    Result.RelativeButtons[0] := Result.RelativeButtons[0] + FKeyboard.Buttons;
    Result.Buttons2 := Result.Buttons2 + FKeyboard.Buttons2;
    Result.Buttons3 := Result.Buttons3 + FKeyboard.Buttons3;
    Result.Buttons4 := Result.Buttons4 + FKeyboard.Buttons4;
  end;
  if GetUsesPointer then
  begin
    if FPointerValid then
    begin
      Result.Analog[0].Valid := True;
      Result.Analog[0].X := EnsureRange(Int64(FPointerX) * 65535 div Max(1, FPictureWidth - 1) - 32768, -32768, 32767);
      Result.Analog[0].Y := EnsureRange(Int64(FPointerY) * 65535 div 223 - 32768, -32768, 32767);
    end;
    if FMouseButtons and 1 <> 0 then
      Include(Result.Buttons, TEmulatorButton.A);
    if FMouseButtons and 2 <> 0 then
      Include(Result.Buttons, TEmulatorButton.B);
  end;
  if FPorts.Devices[0] = 'none' then
  begin
    Result.Buttons := [];
    Result.Analog[0].Valid := False;
    Result.AnalogButtons[0] := Default(TEmulatorAnalogButtons);
    Result.RelativeButtons[0] := [];
  end;
  if FPorts.Devices[1] = 'none' then
  begin
    Result.Buttons2 := [];
    Result.Analog[1].Valid := False;
    Result.AnalogButtons[1] := Default(TEmulatorAnalogButtons);
    Result.RelativeButtons[1] := [];
  end;
  if FPorts.Devices[2] = 'none' then
  begin
    Result.Buttons3 := [];
    Result.Analog[2].Valid := False;
    Result.AnalogButtons[2] := Default(TEmulatorAnalogButtons);
    Result.RelativeButtons[2] := [];
  end;
  if FPorts.Devices[3] = 'none' then
  begin
    Result.Buttons4 := [];
    Result.Analog[3].Valid := False;
    Result.AnalogButtons[3] := Default(TEmulatorAnalogButtons);
    Result.RelativeButtons[3] := [];
  end;
  if FCart.RomSet.Inputs = 'radm' then
  begin
    // Rad Mobile has a wheel and two pedals, not an up/down joystick.
    // Resolve directional aliases after merging/filtering input so releases,
    // custom keys, virtual controls and disabled ports keep their semantics.
    Result.AliasButton(TEmulatorButton.Up, TEmulatorButton.A);
    Result.AliasButton(TEmulatorButton.Down, TEmulatorButton.B);
  end;
end;

function TS32CoreAdapter.GetSystemId: string;
begin
  Result := 'system32';
end;

function TS32CoreAdapter.GetName: string;
begin
  Result := 'Sega System 32';
end;

function TS32CoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TS32CoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

function TS32CoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := True;
end;

function TS32CoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

function TS32CoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  Configure;
  Result := (FWorker <> nil) and FWorker.TryGetFrame(Frame, FRegions);
  if Result then
    FPictureWidth := Frame.Width;
end;

function TS32CoreAdapter.GetVideoRegions: TArray<TRect>;
begin
  Result := Copy(FRegions);
end;

function TS32CoreAdapter.GetUsesPointer: Boolean;
begin
  Result := (FCart.RomSet.Inputs = 'alien3') or (FCart.RomSet.Inputs = 'jpark');
end;

procedure TS32CoreAdapter.SetPointer(X, Y: Integer; Valid: Boolean);
begin
  // A stationary host cursor must not keep reclaiming aim after a pad moved.
  if not Valid then
    FPointerValid := False
  else if not FPointerSeen or (X <> FPointerX) or (Y <> FPointerY) then
    FPointerValid := True;
  FPointerX := X;
  FPointerY := Y;
  FPointerSeen := Valid;
  Configure;
end;

procedure TS32CoreAdapter.SendMouseDelta(DX, DY: Integer; Buttons: Byte);
begin
  FMouseButtons := Buttons;
  Configure;
end;

function TS32CoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FWorker <> nil) then
    Result := FWorker.TakeError;
end;

function TS32CoreAdapter.TakeAudioError: string;
begin
  Result := FAudioError;
  FAudioError := '';
  if (Result = '') and (FWorker <> nil) then
    Result := FWorker.TakeAudioError;
end;

function TS32CoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TS32CoreAdapter.GetVirtualButtons: TEmulatorButtons;
begin
  Result := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right,
      TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z,
      TEmulatorButton.Select, TEmulatorButton.Start, TEmulatorButton.Mode];
  if FCart.RomSet.Inputs.StartsWith('spidman') or FCart.RomSet.Inputs.StartsWith('arabfgt') then
    Result := Result - [TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z]
  else if FCart.RomSet.Inputs = 'sonic' then
    Result := Result - [TEmulatorButton.B, TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z]
  else if FCart.RomSet.Inputs = 'radm' then
    Result := Result - [TEmulatorButton.C, TEmulatorButton.Z]
  else if FCart.RomSet.Inputs.StartsWith('ga2') then
    Result := Result - [TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z]
  else if FCart.RomSet.Inputs = 'jpark' then
    Result := Result - [TEmulatorButton.B, TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z]
  else if FCart.RomSet.Inputs = 'darkedge' then
    Result := Result - [TEmulatorButton.Z]
  else if FCart.RomSet.Inputs = 'kokoroj2' then
    Result := Result - [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.Y, TEmulatorButton.Z]
  else if FCart.RomSet.Inputs = 'f1en' then
    Result := Result - [TEmulatorButton.Y, TEmulatorButton.Z]
  else if (FCart.RomSet.Inputs = 'radr') or (FCart.RomSet.Inputs = 'slipstrm') then
    Result := Result - [TEmulatorButton.B, TEmulatorButton.Y, TEmulatorButton.Z];
  if (FCart.RomSet.Inputs = 'alien3') or (FCart.RomSet.Inputs = 'arescue') then
    Result := Result - [TEmulatorButton.Start];
end;

procedure TS32CoreAdapter.SaveSnapshot(const Name: string);
begin
  if FWorker = nil then
    raise EInvalidOpException.Create('System 32 core is stopped');

  FWorker.Snapshot(Name, False);
end;

procedure TS32CoreAdapter.LoadSnapshot(const Name: string);
begin
  if FWorker = nil then
    raise EInvalidOpException.Create('System 32 core is stopped');

  FWorker.Snapshot(Name, True);
end;

end.

