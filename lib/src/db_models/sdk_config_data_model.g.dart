// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sdk_config_data_model.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class SdkConfigDataModelAdapter extends TypeAdapter<SdkConfigDataModel> {
  @override
  final typeId = 3;

  @override
  SdkConfigDataModel read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SdkConfigDataModel(
      eventPublishEndpoint: fields[0] as String,
      priorities: (fields[1] as List).cast<int>(),
      isEnabled: fields[2] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, SdkConfigDataModel obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.eventPublishEndpoint)
      ..writeByte(1)
      ..write(obj.priorities)
      ..writeByte(2)
      ..write(obj.isEnabled);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SdkConfigDataModelAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
