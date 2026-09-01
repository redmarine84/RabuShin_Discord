public static class CharacterPortraitFileValidator
{
    public const long MaxFileSize = 5L * 1024L * 1024L;

    private static readonly HashSet<string> AllowedContentTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "image/png",
        "image/jpeg",
        "image/webp"
    };

    public static async Task ValidateAsync(IFormFile file, CancellationToken cancellationToken = default)
    {
        if (file.Length <= 0)
            throw new ArgumentException("Choose a portrait image first.");
        if (file.Length > MaxFileSize)
            throw new ArgumentException("Character portraits must be 5 MB or smaller.");
        if (!AllowedContentTypes.Contains(file.ContentType))
            throw new ArgumentException("Character portraits must be PNG, JPEG, or WebP images.");

        await using var stream = file.OpenReadStream();
        var header = new byte[12];
        var read = await stream.ReadAsync(header.AsMemory(0, header.Length), cancellationToken);
        if (!MatchesFileSignature(header, read, file.ContentType))
            throw new ArgumentException("The selected file does not contain a valid PNG, JPEG, or WebP image.");
    }

    private static bool MatchesFileSignature(byte[] header, int read, string contentType)
    {
        if (contentType.Equals("image/png", StringComparison.OrdinalIgnoreCase))
            return read >= 8 && header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4E && header[3] == 0x47 &&
                   header[4] == 0x0D && header[5] == 0x0A && header[6] == 0x1A && header[7] == 0x0A;

        if (contentType.Equals("image/jpeg", StringComparison.OrdinalIgnoreCase))
            return read >= 3 && header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF;

        if (contentType.Equals("image/webp", StringComparison.OrdinalIgnoreCase))
            return read >= 12 &&
                   header[0] == (byte)'R' && header[1] == (byte)'I' && header[2] == (byte)'F' && header[3] == (byte)'F' &&
                   header[8] == (byte)'W' && header[9] == (byte)'E' && header[10] == (byte)'B' && header[11] == (byte)'P';

        return false;
    }
}
