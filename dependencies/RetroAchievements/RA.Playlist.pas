unit RA.Playlist;

interface

uses
  System.Classes;

type
  // Reads UTF-8 playlist lines from the stream's current position. The stream is borrowed.
  TRAPlaylistReader = class
  private
    FStream: TStream;
    FBuffer: array[0..1023] of Byte;
    FNext, FCount: Integer;
    FFirstLine, FEndOfPlaylist, FLastLineTerminated: Boolean;
  public
    constructor Create(Stream: TStream);
    function ReadLine(out Line: string): Boolean;
    property LastLineTerminated: Boolean read FLastLineTerminated;
  end;

function IsRAPlaylistWhitespace(Value: Char): Boolean;

implementation

uses
  System.SysUtils;

function IsRAPlaylistWhitespace(Value: Char): Boolean;
begin
  Result := CharInSet(Value, [#9..#13, ' ']);
end;

constructor TRAPlaylistReader.Create(Stream: TStream);
begin
  inherited Create;
  FStream := Stream;
  FFirstLine := True;
end;

function TRAPlaylistReader.ReadLine(out Line: string): Boolean;
var
  Bytes: UTF8String;
  Start, Count, OldLength: Integer;
  LineEnded: Boolean;
begin
  Line := '';
  LineEnded := False;
  while not FEndOfPlaylist do
  begin
    if FNext = FCount then
    begin
      FCount := FStream.Read(FBuffer[0], SizeOf(FBuffer));
      FNext := 0;
      if (FCount < 0) or (FCount > SizeOf(FBuffer)) then
      begin
        FEndOfPlaylist := True;
        raise EReadError.Create('Invalid RetroAchievements playlist read length');
      end;
      if FCount = 0 then
      begin
        FEndOfPlaylist := True;
        Break;
      end;
    end;

    Start := FNext;
    while (FNext < FCount) and not (FBuffer[FNext] in [0, 10]) do
      Inc(FNext);
    Count := FNext - Start;
    if Count > 0 then
    begin
      OldLength := Length(Bytes);
      SetLength(Bytes, OldLength + Count);
      Move(FBuffer[Start], Bytes[OldLength + 1], Count);
    end;

    if FNext = FCount then
      Continue;
    FEndOfPlaylist := FBuffer[FNext] = 0;
    LineEnded := not FEndOfPlaylist;
    Inc(FNext);
    Break;
  end;

  Result := LineEnded or (Bytes <> '');
  if Result then
  begin
    Line := UTF8ToString(Bytes);
    FLastLineTerminated := LineEnded;
    if FFirstLine and (Line <> '') and (Line[1] = #$FEFF) then
      Delete(Line, 1, 1);
    FFirstLine := False;
  end;
end;

end.
