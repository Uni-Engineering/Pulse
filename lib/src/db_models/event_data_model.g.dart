// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'event_data_model.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class EventDataModelAdapter extends TypeAdapter<EventDataModel> {
  @override
  final typeId = 2;

  @override
  EventDataModel read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return EventDataModel(
      eventId: fields[0] as String,
      eventName: fields[1] as String,
      payload: (fields[2] as Map).cast<String, dynamic>(),
      status:
          fields[3] == null ? EventStatus.pending : fields[3] as EventStatus,
    );
  }

  @override
  void write(BinaryWriter writer, EventDataModel obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.eventId)
      ..writeByte(1)
      ..write(obj.eventName)
      ..writeByte(2)
      ..write(obj.payload)
      ..writeByte(3)
      ..write(obj.status);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EventDataModelAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class EventStatusAdapter extends TypeAdapter<EventStatus> {
  @override
  final typeId = 1;

  @override
  EventStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return EventStatus.pending;
      case 1:
        return EventStatus.readyToSync;
      case 2:
        return EventStatus.synced;
      case 3:
        return EventStatus.failed;
      default:
        return EventStatus.pending;
    }
  }

  @override
  void write(BinaryWriter writer, EventStatus obj) {
    switch (obj) {
      case EventStatus.pending:
        writer.writeByte(0);
      case EventStatus.readyToSync:
        writer.writeByte(1);
      case EventStatus.synced:
        writer.writeByte(2);
      case EventStatus.failed:
        writer.writeByte(3);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EventStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
