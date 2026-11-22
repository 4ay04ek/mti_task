const apiUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'http://192.168.0.214:8080',
);
const issuer = String.fromEnvironment(
  'AUTH_ISSUER',
  defaultValue: 'http://192.168.0.214:8080/realms/zayavka',
);
const mobileClientId = 'zayavka-mobile';
const redirectUrl = 'com.example.zayavka:/oauthredirect';
