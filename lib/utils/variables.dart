class AppValues {
  static const String LANG = "Language";
  // Свой сервер в Астане (PS Cloud). До этого приложение ходило на
  // se-mobile.onrender.com — бесплатный тариф в США, засыпавший после
  // простоя, с базой во Франкфурте.
  //
  // Подменяется при сборке: `--dart-define=API_BASE_URL=http://127.0.0.1:5000`
  // — чтобы проверить сборку (например, для компьютера) на сервере,
  // запущенном у себя, не трогая настоящий.
  static const String baseUrl = String.fromEnvironment('API_BASE_URL',
      defaultValue: 'https://api.se-btrz.com');
}