unit NES.State;

interface

uses
  System.Classes;

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
    procedure Field(var Value; Size: Integer);
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

procedure ReplaceSnapshotFile(const Temporary, Destination: string);
begin
  TStorage.Default.Replace(Temporary, Destination);
end;

end.

