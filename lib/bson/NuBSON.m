#import "NuBSON.h"
#include "bson.h"

@protocol NuCellProtocol
- (id) car;
- (id) cdr;
@end

@protocol NuSymbolProtocol
- (NSString *) labelName;
@end

@interface NuBSON (Private)
- (NuBSON *) initWithBSON:(bson) b;
- (id) initWithObjectIDPointer:(const bson_oid_t *) objectIDPointer;
@end

@implementation NuBSONObjectID

+ (NuBSONObjectID *) objectID
{
    bson_oid_t oid;
    bson_oid_gen(&oid);
    return [[[NuBSONObjectID alloc] initWithObjectIDPointer:&oid] autorelease];
}

- (id) initWithString:(NSString *) s
{
    if (self = [super init]) {
        bson_oid_from_string(&oid, [s cStringUsingEncoding:NSUTF8StringEncoding]);
    }
    return self;
}

- (id) initWithObjectIDPointer:(const bson_oid_t *) objectIDPointer
{
    if (self = [super init]) {
        oid = *objectIDPointer;
    }
    return self;
}

- (const bson_oid_t *) objectIDPointer {return &oid;}

- (NSString *) description
{
    char buffer[25];                              /* str must be at least 24 hex chars + null byte */
    bson_oid_to_string(&oid, buffer);
    return [NSString stringWithFormat:@"(oid \"%s\")", buffer];
}

- (NSString *) stringValue
{
    char buffer[25];                              /* str must be at least 24 hex chars + null byte */
    bson_oid_to_string(&oid, buffer);
    return [NSString stringWithCString:buffer encoding:NSUTF8StringEncoding];
}

- (NSComparisonResult)compare:(NuBSONObjectID *) other
{
    for (int i = 0; i < 3; i++) {
        int diff = oid.ints[i] - other->oid.ints[i];
        if (diff < 0)
            return NSOrderedAscending;
        else if (diff > 0)
            return NSOrderedDescending;
    }
    return  NSOrderedSame;
}

- (BOOL)isEqual:(id)other
{
    return ([self compare:other] == 0);
}

@end

@implementation NuBSON

- (NuBSON *) initWithBSON:(bson) b
{
    if (self = [super init]) {
        bsonValue = b;
    }
    return self;
}

- (NSData *) data
{
    return [[[NSData alloc] initWithBytes:(bsonValue.data) length:bson_size(&(bsonValue))] autorelease];
}

void add_object_to_bson_buffer(bson_buffer *bb, id key, id object)
{
    const char *name = [key cStringUsingEncoding:NSUTF8StringEncoding];
    Class NuCell = NSClassFromString(@"NuCell");
    Class NuSymbol = NSClassFromString(@"NuSymbol");

    if ([object isKindOfClass:[NSNumber class]]) {
        const char *objCType = [object objCType];
        switch (*objCType) {
            case 'd':
            case 'f':
                bson_append_double(bb, name, [object doubleValue]);
                break;
            case 'l':
            case 'L':
                bson_append_long(bb, name, [object longValue]);
                break;
            case 'q':
            case 'Q':
                bson_append_long(bb, name, [object longLongValue]);
                break;
            case 'B':
                bson_append_bool(bb, name, [object boolValue]);
                break;
            case 'c':
            case 'C':
            case 's':
            case 'S':
            case 'i':
            case 'I':
            default:
                bson_append_int(bb, name, [object intValue]);
                break;
        }
    }
    else if ([object isKindOfClass:[NSDictionary class]]) {
        bson_buffer *sub = bson_append_start_object(bb, name);
        id keys = [object allKeys];
        for (int i = 0; i < [keys count]; i++) {
            id key = [keys objectAtIndex:i];
            add_object_to_bson_buffer(sub, key, [object objectForKey:key]);
        }
        bson_append_finish_object(sub);
    }
    else if ([object isKindOfClass:[NSArray class]]) {
        bson_buffer *arr = bson_append_start_array(bb, name);
        for (int i = 0; i < [object count]; i++) {
            add_object_to_bson_buffer(arr, [[NSNumber numberWithInt:i] stringValue], [object objectAtIndex:i]);
        }
        bson_append_finish_object(arr);
    }
    else if ([object isKindOfClass:[NSNull class]]) {
        bson_append_null(bb, name);
    }
    else if ([object isKindOfClass:[NSDate class]]) {
        bson_date_t millis = (bson_date_t) ([object timeIntervalSince1970] * 1000.0);
        bson_append_date(bb, name, millis);
    }
    else if ([object isKindOfClass:[NSData class]]) {
        bson_append_binary(bb, name, 0, [object bytes], [object length]);
    }
    else if ([object isKindOfClass:[NuBSONObjectID class]]) {
        bson_append_oid(bb, name, [((NuBSONObjectID *) object) objectIDPointer]);
    }
    else if (NuCell && [object isKindOfClass:[NuCell class]]) {
        if ([[object car] isKindOfClass:[NuSymbol class]] && (([object length] % 2) == 0)) {
            // assume we have an object
            bson_buffer *sub = bson_append_start_object(bb, name);
            id cursor = object;
            while (cursor && (cursor != [NSNull null])) {
                id key = [[cursor car] labelName];
                id value = [[cursor cdr] car];
                add_object_to_bson_buffer(sub, key, value);
                cursor = [[cursor cdr] cdr];
            }
            bson_append_finish_object(sub);
        }
        else {
            // assume we have an array
            bson_buffer *arr = bson_append_start_array(bb, name);
            id cursor = object;
            int i = 0;
            while (cursor && (cursor != [NSNull null])) {
                add_object_to_bson_buffer(arr, [[NSNumber numberWithInt:i] stringValue], [cursor car]);
                i++;
                cursor = [cursor cdr];
            }
            bson_append_finish_object(arr);
        }
    }
    else if ([object respondsToSelector:@selector(cStringUsingEncoding:)]) {
        bson_append_string(bb, name,[object cStringUsingEncoding:NSUTF8StringEncoding]);
    }
    else {
        NSLog(@"We have a problem. %@ cannot be serialized to bson", object);
    }
}

- (NuBSON *) initWithDictionary:(NSDictionary *) dict
{
    bson b;
    bson_buffer bb;
    bson_buffer_init(& bb );
    id keys = [dict allKeys];
    for (int i = 0; i < [keys count]; i++) {
        id key = [keys objectAtIndex:i];
        add_object_to_bson_buffer(&bb, key, [dict objectForKey:key]);
    }
    bson_from_buffer(&b, &bb);
    return [self initWithBSON:b];
}

- (NuBSON *) initWithList:(id) cell
{
    bson b;
    bson_buffer bb;
    bson_buffer_init(& bb );
    id cursor = cell;
    while (cursor && (cursor != [NSNull null])) {
        id key = [[cursor car] labelName];
        id value = [[cursor cdr] car];
        add_object_to_bson_buffer(&bb, key, value);
        cursor = [[cursor cdr] cdr];
    }
    bson_from_buffer(&b, &bb);
    return [self initWithBSON:b];
}

void dump_bson_iterator(bson_iterator it, const char *indent)
{
    bson_iterator it2;
    bson subobject;

    char more_indent[2000];
    sprintf(more_indent, "  %s", indent);

    while(bson_iterator_next(&it)) {
        fprintf(stderr, "%s  %s: ", indent, bson_iterator_key(&it));
        char hex_oid[25];

        switch(bson_iterator_type(&it)) {
            case bson_double:
                fprintf(stderr, "(double) %e\n", bson_iterator_double(&it));
                break;
            case bson_int:
                fprintf(stderr, "(int) %d\n", bson_iterator_int(&it));
                break;
            case bson_string:
                fprintf(stderr, "(string) \"%s\"\n", bson_iterator_string(&it));
                break;
            case bson_oid:
                bson_oid_to_string(bson_iterator_oid(&it), hex_oid);
                fprintf(stderr, "(oid) \"%s\"\n", hex_oid);
                break;
            case bson_object:
                fprintf(stderr, "(subobject) {...}\n");
                bson_iterator_subobject(&it, &subobject);
                bson_iterator_init(&it2, subobject.data);
                dump_bson_iterator(it2, more_indent);
                break;
            case bson_array:
                fprintf(stderr, "(array) [...]\n");
                bson_iterator_subobject(&it, &subobject);
                bson_iterator_init(&it2, subobject.data);
                dump_bson_iterator(it2, more_indent);
                break;
            default:
                fprintf(stderr, "(type %d)\n", bson_iterator_type(&it));
                break;
        }
    }
}

- (void) dump
{
    bson_iterator it;
    bson_iterator_init(&it, bsonValue.data);
    dump_bson_iterator(it, "");
    fprintf(stderr, "\n");
}

void add_bson_to_object(bson_iterator it, id object)
{
    bson_iterator it2;
    bson subobject;

    while(bson_iterator_next(&it)) {

        NSString *key = [[[NSString alloc]
            initWithCString:bson_iterator_key(&it) encoding:NSUTF8StringEncoding]
            autorelease];

        id value = nil;
        switch(bson_iterator_type(&it)) {
            case bson_eoo:
                break;
            case bson_double:
                value = [NSNumber numberWithDouble:bson_iterator_double(&it)];
                break;
            case bson_string:
                value = [[[NSString alloc]
                    initWithCString:bson_iterator_string(&it) encoding:NSUTF8StringEncoding]
                    autorelease];
                break;
            case bson_object:
                value = [NSMutableDictionary dictionary];
                bson_iterator_subobject(&it, &subobject);
                bson_iterator_init(&it2, subobject.data);
                add_bson_to_object(it2, value);
                break;
            case bson_array:
                value = [NSMutableArray array];
                bson_iterator_subobject(&it, &subobject);
                bson_iterator_init(&it2, subobject.data);
                add_bson_to_object(it2, value);
                break;
            case bson_bindata:
                value = [NSData
                    dataWithBytes:bson_iterator_bin_data(&it)
                    length:bson_iterator_bin_len(&it)];
                break;
            case bson_undefined:
                break;
            case bson_oid:
                value = [[[NuBSONObjectID alloc] initWithObjectIDPointer:bson_iterator_oid(&it)] autorelease];
                break;
            case bson_bool:
                value = [NSNumber numberWithBool:bson_iterator_bool(&it)];
                break;
            case bson_date:
                value = [NSDate dateWithTimeIntervalSince1970:(0.001 * bson_iterator_date(&it))];
                break;
            case bson_null:
                value = [NSNull null];
                break;
            case bson_regex:
                break;
            case bson_code:
                break;
            case bson_symbol:
                break;
            case bson_codewscope:
                break;
            case bson_int:
                value = [NSNumber numberWithInt:bson_iterator_int(&it)];
                break;
            case bson_timestamp:
                break;
            case bson_long:
                value = [NSNumber numberWithLong:bson_iterator_long(&it)];
                break;
            default:
                break;
        }
        if (value) {
            if ([object isKindOfClass:[NSDictionary class]]) {
                [object setObject:value forKey:key];
            }
            else if ([object isKindOfClass:[NSArray class]]) {
                [object addObject:value];
            }
            else {
                fprintf(stderr, "(type %d)\n", bson_iterator_type(&it));
                NSLog(@"we don't know how to add to %@", object);
            }
        }
    }
}

- (NSMutableDictionary *) dictionaryValue
{
    id object = [NSMutableDictionary dictionary];
    bson_iterator it;
    bson_iterator_init(&it, bsonValue.data);
    add_bson_to_object(it, object);
    return object;
}

@end

bson *bson_for_object(id object)
{
    bson *b = 0;
    if (!object) {
        object = [NSDictionary dictionary];
    }
    if ([object isKindOfClass:[NuBSON class]]) {
        b = &(((NuBSON *)object)->bsonValue);
    }
    else if ([object isKindOfClass:[NSDictionary class]]) {
        NuBSON *bsonObject = [[[NuBSON alloc] initWithDictionary:object] autorelease];
        b = &(bsonObject->bsonValue);
    }
    else {
        NSLog(@"unable to convert objects of type %s to BSON (%@).", object_getClassName(object), object);
    }
    return b;
}

@implementation NSData (NuBSON)

- (NSMutableDictionary *) BSONValue
{
    bson bsonValue;
    bsonValue.data = (char *) [self bytes];
    bsonValue.owned = NO;
    NuBSON *bsonObject = [[[NuBSON alloc] initWithBSON:bsonValue] autorelease];
    return [bsonObject dictionaryValue];
}

@end

@implementation NSDictionary (NuBSON)

- (NSData *) BSONRepresentation
{
    NuBSON *bsonObject = [[[NuBSON alloc] initWithDictionary:self] autorelease];
    return [bsonObject data];
}

@end

@implementation NuBSONBuffer

- (id) init
{
    if (self = [super init]) {
        bson_buffer_init(& bb );
    }
    return self;
}

- (NuBSON *) bsonValue
{
    bson b;
    bson_from_buffer(&b, &bb);
    return [[[NuBSON alloc] initWithBSON:b] autorelease];
}

- (void) addObject:(id) object withKey:(id) key
{
    add_object_to_bson_buffer(&bb, key, object);
}

@end
