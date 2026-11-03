unit PSP.State.Direct;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PSP.State;

type
  TPSPStateFile = class
  public
    Kind: Integer;
    HasHistory: Boolean;
    Seed: TPSPReplayState;
    CurrentFiles, Core: TBytes;
    constructor Create;
    destructor Destroy; override;
    procedure Transfer(State: TStateArchive);
  end;

function PSPPackState(Stream: TMemoryStream): TBytes;

function PSPUnpackState(const Data: TBytes): TMemoryStream;

implementation

uses
  System.ZLib;

const
  MaxRawState = Int64(256) * 1024 * 1024;

constructor TPSPStateFile.Create;
begin
  inherited;
  Kind := 2;
  Seed := TPSPReplayState.Create;
end;

destructor TPSPStateFile.Destroy;
begin
  Seed.Free;
  inherited;
end;

procedure TPSPStateFile.Transfer(State: TStateArchive);
begin
  State.Field(Kind, SizeOf(Kind));
  case Kind of
    1:
      Seed.Transfer(State, True);
    2:
      begin
        State.Field(HasHistory, SizeOf(HasHistory));
        Seed.Transfer(State);
        PSPStateBytes(State, CurrentFiles, 48 * 1024 * 1024 + 65536);
        PSPStateBytes(State, Core, 64 * 1024 * 1024);
      end;
  else
    raise EReadError.Create('Unsupported PSP snapshot format');
  end;
end;

function PSPPackState(Stream: TMemoryStream): TBytes;
begin
  if Stream.Size > MaxRawState then
    raise EWriteError.Create('PSP direct state exceeds its uncompressed limit');
  var Output := TMemoryStream.Create;
  try
    var Compressed := TZCompressionStream.Create(Output);
    try
      Stream.Position := 0;
      Compressed.CopyFrom(Stream, Stream.Size);
    finally
      Compressed.Free;
    end;
    SetLength(Result, Output.Size);
    if Length(Result) > 0 then
      Move(Output.Memory^, Result[0], Length(Result));
  finally
    Output.Free;
  end;
end;

function PSPUnpackState(const Data: TBytes): TMemoryStream;
begin
  Result := TMemoryStream.Create;
  var Input := TBytesStream.Create(Data);
  try
    try
      var Reader := TZDecompressionStream.Create(Input);
      try
        var Buffer: array[0..65535] of Byte;
        while True do
        begin
          var N := Reader.Read(Buffer, SizeOf(Buffer));
          if N = 0 then
            Break;
          if Result.Size + N > MaxRawState then
            raise EReadError.Create('PSP direct state exceeds its uncompressed limit');
          Result.WriteBuffer(Buffer, N);
        end;
      finally
        Reader.Free;
      end;
      Result.Position := 0;
    except
      Result.Free;
      raise;
    end;
  finally
    Input.Free;
  end;
end;

end.

