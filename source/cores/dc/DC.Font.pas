unit DC.Font;

// Dreamcast boot ROM layout adapter; shared glyph generation is unchanged.
interface

procedure DCWriteFont(Dest: PByte);

implementation

uses Media.Font.Hershey;

procedure DCWriteFont(Dest: PByte);
begin HersheyWriteLatinFont(Dest); end;

end.
