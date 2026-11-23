  // Product 0: the row's factor times X; a zero factor gives +0 and quantum 0.
        MOV     RAX, [RSI + 0]
        MOVQ    RDX, XMM1
        MOV     RCX, RAX
        ADD     RCX, RCX
        JZ      @@Zero0
        MOV     RCX, RDX
        ADD     RCX, RCX
        JZ      @@Zero0
        SHR     RAX, 52
        AND     EAX, $7FF
        SHR     RDX, 52
        AND     EDX, $7FF
  // Q := XA + XB - 2061; the product cut below 2^Q: 52 - Keep = XA + XB - XP - 986 bits.
        LEA     EBX, [RAX + RDX - 2061]
        LEA     EDX, [RAX + RDX - 986]
        MOVSD   XMM0, [RSI + 0]
        MULSD   XMM0, XMM1
        MOVQ    R8, XMM0
        MOV     RAX, R8
        SHR     RAX, 52
        AND     EAX, $7FF
        SUB     EDX, EAX
        MOV     ECX, EDX
        SHR     R8, CL
        SHL     R8, CL
        JMP     @@Done0

@@Zero0:
        XOR     R8, R8
        XOR     EBX, EBX

@@Done0:
  // Product 1: the row's factor times Y; a zero factor gives +0 and quantum 0.
        MOV     RAX, [RSI + 8]
        MOVQ    RDX, XMM2
        MOV     RCX, RAX
        ADD     RCX, RCX
        JZ      @@Zero1
        MOV     RCX, RDX
        ADD     RCX, RCX
        JZ      @@Zero1
        SHR     RAX, 52
        AND     EAX, $7FF
        SHR     RDX, 52
        AND     EDX, $7FF
  // Q := XA + XB - 2061; the product cut below 2^Q: 52 - Keep = XA + XB - XP - 986 bits.
        LEA     EDI, [RAX + RDX - 2061]
        LEA     EDX, [RAX + RDX - 986]
        MOVSD   XMM0, [RSI + 8]
        MULSD   XMM0, XMM2
        MOVQ    R9, XMM0
        MOV     RAX, R9
        SHR     RAX, 52
        AND     EAX, $7FF
        SUB     EDX, EAX
        MOV     ECX, EDX
        SHR     R9, CL
        SHL     R9, CL
        JMP     @@Done1

@@Zero1:
        XOR     R9, R9
        XOR     EDI, EDI

@@Done1:
  // Product 2: the row's factor times Z; a zero factor gives +0 and quantum 0.
        MOV     RAX, [RSI + 16]
        MOVQ    RDX, XMM3
        MOV     RCX, RAX
        ADD     RCX, RCX
        JZ      @@Zero2
        MOV     RCX, RDX
        ADD     RCX, RCX
        JZ      @@Zero2
        SHR     RAX, 52
        AND     EAX, $7FF
        SHR     RDX, 52
        AND     EDX, $7FF
  // Q := XA + XB - 2061; the product cut below 2^Q: 52 - Keep = XA + XB - XP - 986 bits.
        LEA     R12D, [RAX + RDX - 2061]
        LEA     EDX, [RAX + RDX - 986]
        MOVSD   XMM0, [RSI + 16]
        MULSD   XMM0, XMM3
        MOVQ    R10, XMM0
        MOV     RAX, R10
        SHR     RAX, 52
        AND     EAX, $7FF
        SUB     EDX, EAX
        MOV     ECX, EDX
        SHR     R10, CL
        SHL     R10, CL
        JMP     @@Done2

@@Zero2:
        XOR     R10, R10
        XOR     R12D, R12D

@@Done2:
  // The term added, its quantum 16 bits below its leading one (zero: 0).
        MOV     R11, [RSI + 24]
        XOR     R13D, R13D
        MOV     RAX, R11
        ADD     RAX, RAX
        JZ      @@TermZero
        MOV     RAX, R11
        SHR     RAX, 52
        AND     EAX, $7FF
        LEA     R13D, [RAX - 1038]

@@TermZero:
  // The largest magnitude, the first of equal ones, gives the quantum (R14D).
        MOV     RDX, $7FFFFFFFFFFFFFFF
        MOV     RAX, R8
        AND     RAX, RDX
        MOV     R14D, EBX
        MOV     RCX, R9
        AND     RCX, RDX
        CMP     RCX, RAX
        CMOVA   RAX, RCX
        CMOVA   R14D, EDI
        MOV     RCX, R10
        AND     RCX, RDX
        CMP     RCX, RAX
        CMOVA   RAX, RCX
        CMOVA   R14D, R12D
        MOV     RCX, R11
        AND     RCX, RDX
        CMP     RCX, RAX
        CMOVA   RAX, RCX
        CMOVA   R14D, R13D
        TEST    RAX, RAX
        JZ      @@ZeroSum
  // Term 0 cut at 2^Q (R14D): a zero kept, below 2^Q its sign alone.
        MOV     RAX, R8
        ADD     RAX, RAX
        JZ      @@Cut0
        MOV     RAX, R8
        SHR     RAX, 52
        AND     EAX, $7FF
        SUB     EAX, 1023
        SUB     EAX, R14D
        JS      @@Sign0
        MOV     ECX, 52
        SUB     ECX, EAX
        SHR     R8, CL
        SHL     R8, CL
        JMP     @@Cut0

@@Sign0:
        MOV     RAX, $8000000000000000
        AND     R8, RAX

@@Cut0:
  // Term 1 cut at 2^Q (R14D): a zero kept, below 2^Q its sign alone.
        MOV     RAX, R9
        ADD     RAX, RAX
        JZ      @@Cut1
        MOV     RAX, R9
        SHR     RAX, 52
        AND     EAX, $7FF
        SUB     EAX, 1023
        SUB     EAX, R14D
        JS      @@Sign1
        MOV     ECX, 52
        SUB     ECX, EAX
        SHR     R9, CL
        SHL     R9, CL
        JMP     @@Cut1

@@Sign1:
        MOV     RAX, $8000000000000000
        AND     R9, RAX

@@Cut1:
  // Term 2 cut at 2^Q (R14D): a zero kept, below 2^Q its sign alone.
        MOV     RAX, R10
        ADD     RAX, RAX
        JZ      @@Cut2
        MOV     RAX, R10
        SHR     RAX, 52
        AND     EAX, $7FF
        SUB     EAX, 1023
        SUB     EAX, R14D
        JS      @@Sign2
        MOV     ECX, 52
        SUB     ECX, EAX
        SHR     R10, CL
        SHL     R10, CL
        JMP     @@Cut2

@@Sign2:
        MOV     RAX, $8000000000000000
        AND     R10, RAX

@@Cut2:
  // Term 3 cut at 2^Q (R14D): a zero kept, below 2^Q its sign alone.
        MOV     RAX, R11
        ADD     RAX, RAX
        JZ      @@Cut3
        MOV     RAX, R11
        SHR     RAX, 52
        AND     EAX, $7FF
        SUB     EAX, 1023
        SUB     EAX, R14D
        JS      @@Sign3
        MOV     ECX, 52
        SUB     ECX, EAX
        SHR     R11, CL
        SHL     R11, CL
        JMP     @@Cut3

@@Sign3:
        MOV     RAX, $8000000000000000
        AND     R11, RAX

@@Cut3:
        MOVQ    XMM0, R8
        MOVQ    XMM4, R9
        ADDSD   XMM0, XMM4
        MOVQ    XMM4, R10
        ADDSD   XMM0, XMM4
        MOVQ    XMM4, R11
        ADDSD   XMM0, XMM4
  // T24 of the sum: a zero kept, a normal one cut to 16 bits.
        MOVQ    RAX, XMM0
        MOV     RCX, RAX
        SHR     RCX, 52
        AND     ECX, $7FF
        JZ      @@RowResult
        MOV     RCX, $FFFFFFE000000000
        AND     RAX, RCX
        MOVQ    XMM0, RAX
        JMP     @@RowResult

@@ZeroSum:
        XORPD   XMM0, XMM0

