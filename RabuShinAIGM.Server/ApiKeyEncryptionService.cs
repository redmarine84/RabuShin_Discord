using System.Security.Cryptography;
using System.Text;

public sealed class ApiKeyEncryptionService
{
    private const byte FormatVersion = 1;
    private const int NonceSize = 12;
    private const int TagSize = 16;
    private readonly string? _encodedKey;

    public ApiKeyEncryptionService(IConfiguration configuration)
    {
        _encodedKey = configuration["Security:ApiKeyEncryptionKey"];
    }

    private byte[] GetKey()
    {
        if (string.IsNullOrWhiteSpace(_encodedKey))
            throw new InvalidOperationException(
                "Security:ApiKeyEncryptionKey is not configured. Run SETUP_PUBLIC_RELEASE_SECRETS.cmd before saving player API keys.");

        byte[] key;
        try
        {
            key = Convert.FromBase64String(_encodedKey.Trim());
        }
        catch (FormatException ex)
        {
            throw new InvalidOperationException("Security:ApiKeyEncryptionKey must be a Base64-encoded 32-byte key.", ex);
        }

        if (key.Length != 32)
            throw new InvalidOperationException("Security:ApiKeyEncryptionKey must decode to exactly 32 bytes.");

        return key;
    }

    public string Encrypt(string plaintext)
    {
        if (string.IsNullOrWhiteSpace(plaintext))
            throw new ArgumentException("OpenAI API key is required.", nameof(plaintext));

        var clearBytes = Encoding.UTF8.GetBytes(plaintext.Trim());
        var nonce = RandomNumberGenerator.GetBytes(NonceSize);
        var cipher = new byte[clearBytes.Length];
        var tag = new byte[TagSize];

        var key = GetKey();
        using var aes = new AesGcm(key, TagSize);
        aes.Encrypt(nonce, clearBytes, cipher, tag);

        var packed = new byte[1 + NonceSize + TagSize + cipher.Length];
        packed[0] = FormatVersion;
        Buffer.BlockCopy(nonce, 0, packed, 1, NonceSize);
        Buffer.BlockCopy(tag, 0, packed, 1 + NonceSize, TagSize);
        Buffer.BlockCopy(cipher, 0, packed, 1 + NonceSize + TagSize, cipher.Length);

        CryptographicOperations.ZeroMemory(clearBytes);
        return Convert.ToBase64String(packed);
    }

    public string Decrypt(string encryptedValue)
    {
        if (string.IsNullOrWhiteSpace(encryptedValue))
            throw new InvalidOperationException("No encrypted OpenAI API key is stored for this player.");

        byte[] packed;
        try
        {
            packed = Convert.FromBase64String(encryptedValue);
        }
        catch (FormatException ex)
        {
            throw new InvalidOperationException("The stored OpenAI API key is not valid encrypted data.", ex);
        }

        if (packed.Length < 1 + NonceSize + TagSize + 1 || packed[0] != FormatVersion)
            throw new InvalidOperationException("The stored OpenAI API key uses an unsupported encryption format.");

        var nonce = packed.AsSpan(1, NonceSize).ToArray();
        var tag = packed.AsSpan(1 + NonceSize, TagSize).ToArray();
        var cipher = packed.AsSpan(1 + NonceSize + TagSize).ToArray();
        var clear = new byte[cipher.Length];

        try
        {
            var key = GetKey();
        using var aes = new AesGcm(key, TagSize);
            aes.Decrypt(nonce, cipher, tag, clear);
            return Encoding.UTF8.GetString(clear);
        }
        catch (CryptographicException ex)
        {
            throw new InvalidOperationException(
                "The stored OpenAI API key could not be decrypted. The server encryption key may have changed.", ex);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clear);
        }
    }
}
