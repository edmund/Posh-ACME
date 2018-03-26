function New-Jws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Security.Cryptography.AsymmetricAlgorithm]$Key,
        [Parameter(Mandatory)]
        [hashtable]$Header,
        [Parameter(Mandatory)]
        [string]$PayloadJson
    )

    # RFC 7515 - JSON Web Signature (JWS)
    # https://tools.ietf.org/html/rfc7515

    # This is not a general JWS implementation. It will specifically
    # cater to making JWS messages for the ACME v2 protocol.
    # https://tools.ietf.org/html/draft-ietf-acme-acme-09

    # validate the key type
    if ($Key -is [Security.Cryptography.RSA]) {
        $IsRSA = $true

        # validate the key size
        # LE supports 2048-4096
        # Windows claims to support 8-bit increments (mod 128)
        if ($Key.KeySize -lt 2048 -or $Key.KeySize -gt 4096 -or ($Key.KeySize % 128) -ne 0) {
            throw "Unsupported RSA key size. Must be 2048-4096 in 8 bit increments."
        }

        # make sure we have a private key to sign with
        if ($Key.PublicOnly) {
            throw "Supplied Key has no private key portion."
        }

    } elseif ($Key -is [Security.Cryptography.ECDsa]) {
        $IsRSA = $false

        # validate the curve size which is exposed via KeySize
        if ($Key.KeySize -ne 256 -and $Key.KeySize -ne 384) {
            throw "Unsupported EC curve. Must be P-256 or P-384"
        }

        # make sure we have a private key to sign with
        # since there's no PublicOnly property, we have to fake it by trying to export
        # the private parameters and catching the error
        try {
            $Key.ExportParameters($true) | Out-Null
        } catch {
            throw "Supplied Key has no private key portion."
        }

    } else {
        throw "Unsupported Key type. Must be RSA or ECDsa"
    }

    # validate the header
    if ('alg' -notin $Header.Keys -or $Header.alg -notin 'RS256','ES256','ES384') {
        throw "Missing or invalid 'alg' in supplied Header"
    }
    if (!('jwk' -in $Header.Keys -xor 'kid' -in $Header.Keys)) {
        if ('jwk' -in $Header.Keys) {
            throw "Conflicting key entries. Both 'jwk' and 'kid' found in supplied Header"
        } else {
            throw "Missing key entries. Neither 'jwk' or 'kid' found in supplied Header"
        }
    }
    if ('jwk' -in $Header.Keys -and [string]::IsNullOrWhiteSpace($Header.jwk)) {
        throw "Empty 'jwk' in supplied Header."
    }
    if ('kid' -in $Header.Keys -and [string]::IsNullOrWhiteSpace($Header.kid)) {
        throw "Empty 'kid' in supplied Header."
    }
    if ('nonce' -notin $Header.Keys -or [string]::IsNullOrWhiteSpace($Header.nonce)) {
        throw "Missing or empty 'nonce' in supplied Header."
    }
    if ('url' -notin $Header.Keys -or [string]::IsNullOrWhiteSpace($Header.url)) {
        throw "Missing or empty 'url' in supplied Header."
    }

    # build the "<protected>.<payload>" string we're going to be signing
    Write-Verbose "Header: $($Header | ConvertTo-Json)"
    $HeaderB64 = ConvertTo-Base64Url ($Header | ConvertTo-Json -Compress)
    Write-Verbose "Payload: $PayloadJson"
    $PayloadB64 = ConvertTo-Base64Url $PayloadJson
    $Message = "$HeaderB64.$PayloadB64"
    $MessageBytes = [Text.Encoding]::ASCII.GetBytes($Message)

    if ($IsRSA) {
        # Make sure header 'alg' matches key type
        if ($Header.alg -ne 'RS256') {
            throw "Supplied Key does not match 'alg' in supplied Header."
        }

        # create the signature
        $HashAlgo = [Security.Cryptography.HashAlgorithmName]::SHA256
        $PaddingType = [Security.Cryptography.RSASignaturePadding]::Pkcs1
        $SignedBytes = $Key.SignData($MessageBytes, $HashAlgo, $PaddingType)
    } else {
        # Make sure header 'alg' matches key type
        if ($Header.alg -ne 'ES256') {
            throw "Supplied key object does not match 'alg' in supplied Header."
        }

        # create the signature
        $SignedBytes = $Key.SignData($MessageBytes)
    }

    # now put everything together into the final JWS format
    $jws = [ordered]@{}
    $jws.payload = $PayloadB64
    $jws.protected = $HeaderB64
    $jws.signature = ConvertTo-Base64Url $SignedBytes

    # and return it
    #Write-Verbose ($jws | ConvertTo-Json)
    return ($jws | ConvertTo-Json -Compress)

}