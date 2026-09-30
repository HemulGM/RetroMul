unit MD.Emulation;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Core.Emulation, MD.Console;

const
  MD_SAMPLE_RATE = 44100;
  AUDIO_BLOCK_SAMPLES = 2048;
  AUDIO_BLOCK_COUNT = 4;

type
  TMDWorker = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FData: TBytes;
    FSavePath: string;
    FInput: TMDButtons;
    FPause, FReset, FAudioEnabled: Boolean;
    FVolume: Single;
    FFrame: TEmulatorFrame;
    FAvailable: Boolean;
    FError: string;
    procedure SetError(const Value: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const Data: TBytes; const SavePath: string);
    destructor Destroy; override;
    procedure WakeSetEvent;
    procedure Configure(const Input: TMDButtons; Paused, AudioEnabled: Boolean; Volume: Single);
    procedure RequestReset;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
  end;

implementation

uses
  System.IOUtils, System.UITypes, System.Diagnostics, System.Math, PCM.Audio;

{ TMDWorker }

constructor TMDWorker.Create(const Data: TBytes; const SavePath: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FData := Copy(Data);
  FSavePath := SavePath;
end;

destructor TMDWorker.Destroy;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;
  inherited Destroy;
  FWake.Free;
  FLock.Free;
end;

procedure TMDWorker.Configure(const Input: TMDButtons; Paused, AudioEnabled: Boolean; Volume: Single);
begin
  FLock.Acquire;
  try
    FInput := Input;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := Volume;
  finally
    FLock.Release;
  end;
end;

procedure TMDWorker.RequestReset;
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

procedure TMDWorker.SetError(const Value: string);
begin
  FLock.Acquire;
  try
    if FError = '' then
      FError := Value
    else
      FError := FError + SLineBreak + Value;
  finally
    FLock.Release;
  end;
end;

function TMDWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TMDWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

procedure TMDWorker.WakeSetEvent;
begin
  FWake.SetEvent;
end;

procedure TMDWorker.Execute;
  procedure SaveBattery(Console: TMDConsole; var LastBattery: TBytes);
  begin
    if (Console = nil) or not Console.BatteryDirty then
      Exit;
    var Data := Console.BatteryData;
    if Length(Data) = 0 then
      Exit;
    var Unchanged := Length(Data) = Length(LastBattery);
    if Unchanged then
      for var I := 0 to High(Data) do
        if Data[I] <> LastBattery[I] then
        begin
          Unchanged := False;
          Break;
        end;
    if Unchanged then
      Exit;
    ForceDirectories(ExtractFilePath(FSavePath));
    var TempName := FSavePath + '.' + TGUID.NewGuid.ToString + '.tmp';
    try
      TFile.WriteAllBytes(TempName, Data);
      if TFile.Exists(FSavePath) then
        TFile.Replace(TempName, FSavePath, '')
      else
        TFile.Move(TempName, FSavePath);
      LastBattery := Data;
    finally
      if TFile.Exists(TempName) then
        TFile.Delete(TempName);
    end;
  end;

begin
  var Format: TPCMAudioFormat;
  var Input: TMDButtons;
  var Paused, ResetRequested, Enabled, WasPaused, WasEnabled: Boolean;
  var Volume: Single;
  var Frame: TEmulatorFrame;
  var Samples: TArray<SmallInt>;
  var Watch: TStopwatch;
  var Deadline: Double;
  var WaitMS: Integer;
  var LastBattery: TBytes;
  var LastAudioError: string;
  var Console: TMDConsole := nil;
  var Audio: TPCMAudio := nil;
  try
    try
      Console := TMDConsole.Create(FData, '.md');
      if TFile.Exists(FSavePath) then
      begin
        LastBattery := TFile.ReadAllBytes(FSavePath);
        Console.LoadBattery(LastBattery);
      end;
      Format.SampleRate := MD_SAMPLE_RATE;
      Format.Channels := 2;
      Format.BlockFrames := AUDIO_BLOCK_SAMPLES;
      Format.BlockCount := AUDIO_BLOCK_COUNT;
      Watch := TStopwatch.StartNew;
      Deadline := 0;
      WasPaused := False;
      WasEnabled := False;
      while not Terminated do
      begin
        FLock.Acquire;
        try
          Input := FInput;
          Paused := FPause;
          Enabled := FAudioEnabled;
          Volume := FVolume;
          ResetRequested := FReset;
          FReset := False;
        finally
          FLock.Release;
        end;
        if ResetRequested then
        begin
          SaveBattery(Console, LastBattery);
          Console.Reset;
          if Audio <> nil then
            Audio.Clear;
          Deadline := Watch.Elapsed.TotalMilliseconds;
        end;
        if Paused then
        begin
          if not WasPaused then
          begin
            if Audio <> nil then
              Audio.Clear;
            SaveBattery(Console, LastBattery);
          end;
          WasPaused := True;
          FWake.WaitFor(10);
          Deadline := Watch.Elapsed.TotalMilliseconds;
          Continue;
        end;
        WasPaused := False;
        Console.SetInput(Input);
        Console.RunFrame;
        if Terminated then
          Break;
        Frame.Width := Console.Width;
        Frame.Height := Console.Height;
        Frame.FrameNumber := Console.FrameNumber;
        Frame.FramesPerSecond := Console.FramesPerSecond;
        // Allocate a new publication buffer: previously delivered frames remain immutable.
        Frame.Pixels := nil;
        SetLength(Frame.Pixels, Frame.Width * Frame.Height);
        for var Y := 0 to Frame.Height - 1 do
          for var X := 0 to Frame.Width - 1 do
            Frame.Pixels[Y * Frame.Width + X] := Console.Pixels[Y * 320 + X];
        FLock.Acquire;
        try
          FFrame := Frame;
          FAvailable := True;
        finally
          FLock.Release;
        end;
        if Enabled then
        begin
          if Audio = nil then
            Audio := TPCMAudio.Create(Format);
          SetLength(Samples, Console.SampleFrames * 2);
          for var I := 0 to High(Samples) do
            Samples[I] := Round(Console.Samples[I] * Volume);
          Audio.Submit(Samples, Console.SampleFrames);
          if (Audio.Error <> '') and (Audio.Error <> LastAudioError) then
          begin
            LastAudioError := Audio.Error;
            SetError('Mega Drive audio: ' + LastAudioError);
          end;
        end
        else if WasEnabled and (Audio <> nil) then
          Audio.Clear;
        WasEnabled := Enabled;
        if Console.FrameNumber mod 120 = 0 then
          SaveBattery(Console, LastBattery);
        Deadline := Deadline + 1000 / Console.FramesPerSecond;
        if Watch.Elapsed.TotalMilliseconds - Deadline > 100 then
          Deadline := Watch.Elapsed.TotalMilliseconds;
        WaitMS := Floor(Deadline - Watch.Elapsed.TotalMilliseconds);
        if WaitMS > 0 then
          FWake.WaitFor(WaitMS);
      end;
    except
      on E: Exception do
        SetError('Mega Drive: ' + E.Message);
    end;
  finally
    try
      SaveBattery(Console, LastBattery);
    except
      on E: Exception do
        SetError('Mega Drive SRAM: ' + E.Message);
    end;
    Audio.Free;
    Console.Free;
  end;
end;

end.

