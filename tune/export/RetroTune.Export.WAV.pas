unit RetroTune.Export.WAV;

interface

uses
  System.Classes, System.SysUtils, System.SyncObjs, RetroTune.Decoder;

type
  // Return False to cancel. Called on the rendering thread, without UI callbacks.
  TTuneExportProgress = reference to function(Frames, TotalFrames: Int64): Boolean;

  TTuneExportState = (Rendering, Completed, Cancelled, Failed);

  TTuneExportStatus = record
    State: TTuneExportState;
    Frames, TotalFrames: Int64;
    SampleRate: Integer;
    Path, Error: string;
  end;

  TTuneWavExport = class(TThread)
  private
    FData: TBytes;
    FExtension: string;
    FTrack: Integer;
    FSeconds: Double;
    FLock: TCriticalSection;
    FStatus: TTuneExportStatus;
    FStarted: Boolean;
    function Progress(Frames, TotalFrames: Int64): Boolean;
  protected
    procedure Execute; override;
  public
    // Keep a private input snapshot; create and use a separate decoder in Execute.
    constructor Create(const Data: TBytes; const Extension, Path: string; Track: Integer; Seconds: Double);
    destructor Destroy; override;
    procedure Cancel;
    function Status: TTuneExportStatus;
  end;

// Resets the selected track, streams until EOF or the requested duration, then
// patches the RIFF sizes. Output must be writable and seekable. No PCM device.
function RenderTuneWav(const Decoder: ITuneDecoder; Output: TStream; Track: Integer; Seconds: Double; const Progress: TTuneExportProgress = nil): Int64;

implementation

uses
  System.Math,
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ELSE}
  Posix.Stdio,
  {$ENDIF}
  System.IOUtils;

procedure WriteLE16(Output: TStream; Value: Word);
var
  Bytes: array[0..1] of Byte;
begin
  Bytes[0] := Byte(Value and $FF);
  Bytes[1] := Byte(Value shr 8);
  Output.WriteBuffer(Bytes, SizeOf(Bytes));
end;

procedure WriteLE32(Output: TStream; Value: Cardinal);
var
  Bytes: array[0..3] of Byte;
begin
  for var I := 0 to 3 do
    Bytes[I] := Byte((Value shr (I * 8)) and $FF);
  Output.WriteBuffer(Bytes, SizeOf(Bytes));
end;

procedure WriteTag(Output: TStream; const Tag: AnsiString);
begin
  Output.WriteBuffer(Tag[1], 4);
end;

function RenderTuneWav(const Decoder: ITuneDecoder; Output: TStream; Track: Integer; Seconds: Double; const Progress: TTuneExportProgress): Int64;
var
  Info: TTuneInfo;
  Samples: TArray<SmallInt>;
  Bytes: TBytes;
  TotalFrames, MaxFrames: Int64;
  Count, Requested, ByteCount: Integer;
  DataSize: Cardinal;

  procedure CheckProgress;
  begin
    if Assigned(Progress) and not Progress(Result, TotalFrames) then
      raise EAbort.Create('WAV export cancelled');
  end;

begin
  if (Decoder = nil) or (Output = nil) then
    raise EArgumentNilException.Create('Decoder and output are required');
  Info := Decoder.GetInfo;
  if (Info.SampleRate < 1) or (Info.SampleRate > 384000) or
    (Info.Channels < 1) or (Info.Channels > 2) then
    raise EArgumentException.Create('Unsupported PCM format');
  if (Track < 0) or (Track >= Info.TrackCount) then
    raise EArgumentOutOfRangeException.Create('Invalid track');
  if IsNan(Seconds) or IsInfinite(Seconds) or (Seconds <= 0) or (Seconds > 86400) then
    raise EArgumentOutOfRangeException.Create('Duration must be between 0 and 86400 seconds');
  MaxFrames := (Int64(High(Cardinal)) - 36) div (Info.Channels * 2);
  if Seconds * Info.SampleRate > MaxFrames then
    raise EArgumentOutOfRangeException.Create('Requested duration exceeds the WAV 4 GiB limit');
  TotalFrames := Max(Int64(1), Round(Seconds * Info.SampleRate));
  Result := 0;
  CheckProgress;
  Decoder.SelectTrack(Track);
  Output.Position := 0;
  Output.Size := 0;
  WriteTag(Output, 'RIFF');
  WriteLE32(Output, 36);
  WriteTag(Output, 'WAVE');
  WriteTag(Output, 'fmt ');
  WriteLE32(Output, 16);
  WriteLE16(Output, 1); // PCM
  WriteLE16(Output, Info.Channels);
  WriteLE32(Output, Info.SampleRate);
  WriteLE32(Output, Info.SampleRate * Info.Channels * 2);
  WriteLE16(Output, Info.Channels * 2);
  WriteLE16(Output, 16);
  WriteTag(Output, 'data');
  WriteLE32(Output, 0);
  SetLength(Samples, 4096 * Info.Channels);
  SetLength(Bytes, Length(Samples) * 2);
  while Result < TotalFrames do
  begin
    CheckProgress;
    Requested := Integer(Min(Int64(4096), TotalFrames - Result));
    Count := Decoder.Render(Samples, Requested);
    if (Count < 0) or (Count > Requested) then
      raise EInvalidOpException.Create('Invalid decoder frame count during WAV export');
    if Count = 0 then
      Break;
    ByteCount := Count * Info.Channels * 2;
    // Serialize explicitly so the WAV is little endian on every target.
    for var I := 0 to Count * Info.Channels - 1 do
    begin
      var Value := Word(Integer(Samples[I]) and $FFFF);
      Bytes[I * 2] := Byte(Value and $FF);
      Bytes[I * 2 + 1] := Byte(Value shr 8);
    end;
    Output.WriteBuffer(Bytes[0], ByteCount);
    Inc(Result, Count);
  end;
  CheckProgress;
  DataSize := Cardinal(Result * Info.Channels * 2);
  Output.Position := 4;
  WriteLE32(Output, 36 + DataSize);
  Output.Position := 40;
  WriteLE32(Output, DataSize);
  Output.Position := Output.Size;
end;

constructor TTuneWavExport.Create(const Data: TBytes; const Extension, Path: string; Track: Integer; Seconds: Double);
begin
  // AfterConstruction starts the worker once all fields are initialized.
  inherited Create(False);
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FData := Copy(Data);
  FExtension := Extension;
  FTrack := Track;
  FSeconds := Seconds;
  FStatus.Path := ExpandFileName(Path);
  FStatus.State := TTuneExportState.Rendering;
  FStarted := True;
end;

destructor TTuneWavExport.Destroy;
begin
  if FLock <> nil then
    Cancel;
  if FStarted then
    WaitFor;
  FLock.Free;
  inherited;
end;

procedure TTuneWavExport.Cancel;
begin
  FLock.Acquire;
  try
    if FStatus.State = TTuneExportState.Rendering then
      Terminate;
  finally
    FLock.Release;
  end;
end;

function TTuneWavExport.Status: TTuneExportStatus;
begin
  FLock.Acquire;
  try
    Result := FStatus;
  finally
    FLock.Release;
  end;
end;

function TTuneWavExport.Progress(Frames, TotalFrames: Int64): Boolean;
begin
  FLock.Acquire;
  try
    FStatus.Frames := Frames;
    FStatus.TotalFrames := TotalFrames;
    Result := not Terminated;
  finally
    FLock.Release;
  end;
end;

procedure TTuneWavExport.Execute;
var
  Temporary: string;
  Decoder: ITuneDecoder;
  Output: TFileStream;
begin
  Temporary := '';
  try
    try
      if Terminated then
        Abort;
      Decoder := TTuneDecoders.OpenData(FData, FExtension);
      FData := nil;
      FLock.Acquire;
      try
        FStatus.SampleRate := Decoder.GetInfo.SampleRate;
      finally
        FLock.Release;
      end;
      Temporary := TPath.Combine(ExtractFilePath(FStatus.Path),
        TGUID.NewGuid.ToString + '.wav.tmp');
      Output := TFileStream.Create(Temporary, fmCreate);
      try
        RenderTuneWav(Decoder, Output, FTrack, FSeconds,
          function(Frames, TotalFrames: Int64): Boolean
          begin
            Result := Progress(Frames, TotalFrames);
          end);
      finally
        Output.Free;
      end;
      // Cancel and publication serialize here: a completed file stays completed.
      FLock.Acquire;
      try
        if Terminated then
          Abort;
        {$IFDEF MSWINDOWS}
        if not MoveFileEx(PChar(Temporary), PChar(FStatus.Path),
          MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
          RaiseLastOSError;
        {$ELSE}
        var Source := UTF8String(Temporary);
        var Target := UTF8String(FStatus.Path);
        if Posix.Stdio.__rename(PAnsiChar(Source), PAnsiChar(Target)) <> 0 then
          RaiseLastOSError;
        {$ENDIF}
        Temporary := '';
        FStatus.State := TTuneExportState.Completed;
      finally
        FLock.Release;
      end;
    finally
      Decoder := nil;
      FData := nil;
      if (Temporary <> '') and TFile.Exists(Temporary) then
        TFile.Delete(Temporary);
    end;
  except
    on E: Exception do
    begin
      FLock.Acquire;
      try
        if E is EAbort then
          FStatus.State := TTuneExportState.Cancelled
        else
        begin
          FStatus.State := TTuneExportState.Failed;
          FStatus.Error := E.Message;
        end;
      finally
        FLock.Release;
      end;
    end;
  end;
end;

end.

