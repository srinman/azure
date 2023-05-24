# Create self-signed certs  

# interactive
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -sha256 -days 365
# non-interactive and 10 years expiration
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -sha256 -days 3650 -nodes -subj "/C=XX/ST=StateName/L=CityName/O=CompanyName/OU=CompanySectionName/CN=CommonNameOrHostname"

# as of 2023 with OpenSSL ≥ 1.1.1, the following command serves all your needs, including Subject Alternate Name (SAN):
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout example.key -out example.crt -subj "/CN=example.com" \
  -addext "subjectAltName=DNS:example.com,DNS:www.example.net,IP:10.0.0.1"
