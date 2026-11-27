unit NES.State;

interface

uses
  System.Classes, Core.Snapshots;

const
  MMC5_AUDIO_STATE_VERSION = 44;
  MMC5_SCANLINE_STATE_VERSION = 45;
  MMC5_TIMER_STATE_VERSION = 46;
  MMC5_CONTROL_PINS_STATE_VERSION = 47;
  T9552_STATE_VERSION = 48;
  MMC3_RELOAD_STATE_VERSION = 49;
  MMC3_IRQ_REVISION_STATE_VERSION = 50;
  MMC3_FCEUX_STATE_VERSION = 51;
  NES_ACHIEVEMENT_STATE_VERSION = 52;
  NES_SNAPSHOT_VERSION = NES_ACHIEVEMENT_STATE_VERSION;

type
  // Explicit field serialization: never persist object pointers or callbacks.
  // Bump the file version whenever the serialized field order/layout changes.
  TNesStateArchive = class
  private
    FStream: TStream;
    FLoading: Boolean;
    FVersion: Integer;
  public
    constructor Create(Stream: TStream; Loading: Boolean; Version: Integer = 3);
    property Version: Integer read FVersion;
    property Loading: Boolean read FLoading;
    procedure SharedFields(const Transfer: TStateTransfer);
    procedure Field(var Value; Size: Integer);
    procedure MemoryLength(var Value: Integer);
  end;

procedure ReplaceSnapshotFile(const Temporary, Destination: string);

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ELSE}
  Posix.Stdio,
  {$ENDIF}
  Core.Storage, System.SysUtils;

constructor TNesStateArchive.Create(Stream: TStream; Loading: Boolean; Version: Integer);
begin
  inherited Create;
  FStream := Stream;
  FLoading := Loading;
  FVersion := Version;
end;

procedure TNesStateArchive.SharedFields(const Transfer: TStateTransfer);
begin
  var Archive := TStateArchive.Create(FStream, FLoading);
  try
    Transfer(Archive);
  finally
    Archive.Free;
  end;
end;

procedure TNesStateArchive.Field(var Value; Size: Integer);
begin
  var StoredSize := Size;
  if FLoading then
  begin
    FStream.ReadBuffer(StoredSize, SizeOf(StoredSize));
    if (StoredSize <> Size) or (Size > FStream.Size - FStream.Position) then
      raise EReadError.Create('Incompatible or truncated snapshot');

    if Size > 0 then
      FStream.ReadBuffer(Value, Size);
  end
  else
  begin
    FStream.WriteBuffer(StoredSize, SizeOf(StoredSize));
    if Size > 0 then
      FStream.WriteBuffer(Value, Size);
  end;
end;

procedure TNesStateArchive.MemoryLength(var Value: Integer);
begin
  if not FLoading then
  begin
    Field(Value, SizeOf(Value));
    Exit;
  end;

  // Older snapshots wrote Length results in the native integer size.
  var StoredSize: Integer;
  FStream.ReadBuffer(StoredSize, SizeOf(StoredSize));
  case StoredSize of
    SizeOf(Integer):
      FStream.ReadBuffer(Value, SizeOf(Value));
    SizeOf(Int64):
      begin
        var Length64: Int64;
        FStream.ReadBuffer(Length64, SizeOf(Length64));
        if (Length64 < 0) or (Length64 > MaxInt) then
          raise EReadError.Create('Invalid snapshot memory length');
        Value := Integer(Length64);
      end;
  else
    raise EReadError.Create('Invalid snapshot memory length');
  end;
end;

procedure ReplaceSnapshotFile(const Temporary, Destination: string);
begin
  TStorage.Default.Replace(Temporary, Destination);
end;

end.

