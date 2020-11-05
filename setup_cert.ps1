#Requires Windows Server 2016

# HPC PACK 2016 cert
# https://github.com/Azure/hpcpack-template-2016#1-prepare-a-pfx-certificate

$pfx_filename = "hpc-comm.pfx"
$plain_password = "corn-bellows-knitting"
$cert = New-SelfSignedCertificate -Subject "CN=HPC Pack 2016 Communication" `
    -KeySpec KeyExchange -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.1,1.3.6.1.5.5.7.3.2") `
    -CertStoreLocation cert:\CurrentUser\My -KeyExportPolicy Exportable -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddYears(5) -NotBefore (Get-Date).AddDays(-1)
$pwd = ConvertTo-SecureString -String $plain_password -Force -AsPlainText
Export-PfxCertificate -cert $cert -FilePath "C:\$pfx_filename" -Password $pwd

