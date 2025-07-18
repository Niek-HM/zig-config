pub const ConfigError = error{
    // --- Lookup & Access ---
    Missing, // Key not found
    UnknownVariable, // Referenced variable not found in config or env
    KeyConflict, // Duplicate key detected during merge
    TypeMismatch, // Value exists but is not of the expected type

    // --- Type Conversion ---
    InvalidType, // Type conversion not supported or not allowed
    InvalidInt, // Failed to parse integer
    InvalidFloat, // Failed to parse float
    InvalidBool, // Failed to parse boolean

    // --- Substitution & Expansion ---
    InvalidPlaceholder, // Empty or malformed placeholder like `${}`
    InvalidSubstitutionSyntax, // Incorrect substitution syntax (e.g., `${VAR:-}`)
    CircularReference, // Variable references itself indirectly (infinite loop)

    // --- Escaping & Encoding ---
    InvalidEscape, // Invalid escape sequence (e.g., `\z`)
    InvalidUnicodeEscape, // Malformed Unicode escape (e.g., `\u12`)
    InvalidCharacter, // Unexpected character in input

    // --- Parsing Errors ---
    InvalidSection,
    MalformedLine,
    DuplicateKey,

    InvalidKey, // Key format is invalid
    InvalidValue, // Value format is invalid
    ParseError, // General parse failure
    ParseInvalidLine, // Line could not be parsed as key=value or section
    ParseUnterminatedSection, // Section header not closed properly
    ParseInvalidFormat, // File format is incorrect or unsupported

    // --- System / Runtime ---
    IoError, // I/O operation failed
    OutOfMemory, // Memory allocation failed
};
