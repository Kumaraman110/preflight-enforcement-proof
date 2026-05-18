FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS base
RUN groupadd -r appuser && useradd -r -g appuser -u 1000 appuser
WORKDIR /app
EXPOSE 8080

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY ["TestService.csproj", "."]
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /app/publish

FROM base AS final
COPY --from=build /app/publish .
USER appuser
ENTRYPOINT ["dotnet", "TestService.dll"]
